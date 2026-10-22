import Foundation
import HealthKit

enum SyncReason: CustomStringConvertible, Sendable {
    case manual
    case foreground
    case observer(String)
    case backgroundRefresh
    case settingsChanged
    case reimport

    var description: String {
        switch self {
        case .manual: "manual"
        case .foreground: "app opened"
        case .observer(let key): "new \(key) data"
        case .backgroundRefresh: "background refresh"
        case .settingsChanged: "settings changed"
        case .reimport: "full re-import"
        }
    }
}

enum CatchUp {
    /// Safety margin subtracted from the server's newest timestamp: sources
    /// like WHOOP backfill days late, and re-sent overlap is free (the
    /// server dedupes by uuid).
    static let margin: TimeInterval = 72 * 3600

    /// Timestamps are clamped to `now` before the margin is applied: a
    /// future-dated server timestamp would otherwise produce an empty
    /// bounded query that persists a store-wide anchor and permanently
    /// skips the type's history.
    static func cutoffs(fromLatest latest: [String: String], now: Date = Date()) -> [String: Date] {
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return latest.compactMapValues { raw in
            guard let parsed = strict.date(from: raw) ?? fractional.date(from: raw) else { return nil }
            return min(parsed, now).addingTimeInterval(-margin)
        }
    }
}

/// Per enabled type: run an anchored query from the last anchor, hand the
/// results to the outbox, and let the outbox persist the new anchor once the
/// server ACKs. An in-memory anchor cache leads the persisted one so
/// overlapping triggers don't re-read samples that are already queued; after
/// a crash the cache is gone, the persisted anchor wins, and any re-read
/// samples dedupe server-side by uuid.
actor SyncEngine {
    static let queryLimit = 5000

    private let healthStore: HKHealthStore
    private let queries: HealthQueries
    private let anchors: AnchorStore
    private let outbox: Outbox
    private let log: LogStore
    private let status: AppStatus
    /// GET /latest from the configured server; nil when unavailable.
    private let latestHints: @Sendable () async -> [String: String]?
    private var anchorCache: [String: HKQueryAnchor] = [:]
    /// Snapshot state as last queued; survives in memory between passes.
    private var snapshotCache: [String: SnapshotState] = [:]
    private var chain: Task<Void, Never>?
    /// Types whose query threw last time (typically authorization not yet
    /// granted for a newly added type). They must not hold the catch-up
    /// gate open on every background wake; cleared on user-visible passes
    /// so a grant is picked up promptly.
    private var authBlocked: Set<String> = []
    /// GET /latest result (including failure) cached briefly so background
    /// wakes don't pay a network round-trip per pass.
    private var latestFetch: (at: Date, hints: [String: String]?)?
    private static let latestCacheInterval: TimeInterval = 15 * 60

    init(
        healthStore: HKHealthStore, anchors: AnchorStore, outbox: Outbox,
        log: LogStore, status: AppStatus,
        latestHints: @escaping @Sendable () async -> [String: String]? = { nil }
    ) {
        self.healthStore = healthStore
        queries = HealthQueries(store: healthStore)
        self.anchors = anchors
        self.outbox = outbox
        self.log = log
        self.status = status
        self.latestHints = latestHints
    }

    /// Every trigger funnels here. Passes are serialized; each caller returns
    /// after its own pass (and the outbox drain it triggers) completes.
    /// `only` limits a pass to those type keys (observer wakes name the
    /// types that changed); nil means every enabled type and snapshot.
    func requestSync(_ reason: SyncReason, only keys: Set<String>? = nil) async {
        let previous = chain
        let task = Task {
            await previous?.value
            await self.performSync(reason, only: keys)
        }
        chain = task
        await task.value
    }

    private func performSync(_ reason: SyncReason, only keys: Set<String>?) async {
        guard AppSettings.currentTarget() != nil else {
            await log.info("sync skipped (\(reason)): no server configured")
            return
        }
        await status.setSyncing(true)
        // Types this OS refused at authorization would only fail their query.
        let refused = HealthAuthorization.lastRejected()
        let enabled = AppSettings.currentEnabledTypes().filter {
            !refused.contains($0.sampleType.identifier) && (keys?.contains($0.key) ?? true)
        }

        // A user-visible pass may follow a permission grant — retry types
        // that were failing. Background wakes keep them excluded.
        switch reason {
        case .manual, .foreground, .settingsChanged, .reimport:
            authBlocked.removeAll()
        case .observer, .backgroundRefresh:
            break
        }

        // Resolve every anchor exactly once; the catch-up gate and the
        // cutoff application below both derive from this resolution. (An
        // anchor file that exists but fails to decode counts as missing —
        // it must trigger catch-up, not an unbounded full read.)
        var resolvedAnchors: [String: HKQueryAnchor] = [:]
        for type in enabled {
            if let anchor = anchorCache[type.key] ?? anchors.load(type.key) {
                resolvedAnchors[type.key] = anchor
            }
        }
        let missing = enabled.map(\.key).filter { resolvedAnchors[$0] == nil && !authBlocked.contains($0) }

        // Catch-up: for types with no anchor (fresh install, newly enabled),
        // ask the server what it already has and skip re-reading history.
        // A full re-import must bypass this, or it couldn't re-send — and
        // the bypass must be durable state, not just this pass's reason:
        // an interleaved or resumed pass would otherwise catch-up against
        // the fully-populated server and defeat the re-import.
        var cutoffs: [String: Date] = [:]
        let reimporting = UserDefaults.standard.bool(forKey: SettingsKeys.reimportPending)
        if !reimporting && !missing.isEmpty {
            if let latest = await cachedLatestHints() {
                let parsed = CatchUp.cutoffs(fromLatest: latest)
                if parsed.count < latest.count {
                    await log.warn("server /latest: \(latest.count - parsed.count) unparseable timestamp(s) ignored")
                }
                cutoffs = parsed.filter { missing.contains($0.key) }
                if !cutoffs.isEmpty {
                    await log.info("server /latest: catching up instead of full backfill for \(cutoffs.count) type(s)")
                }
            }
        }

        var queued = 0
        var anyFailed = false
        for type in enabled {
            do {
                queued += try await sync(type, anchor: resolvedAnchors[type.key], cutoffs: cutoffs)
            } catch {
                anyFailed = true
                authBlocked.insert(type.key)
                await log.error("\(type.key): \(error.localizedDescription)")
            }
        }
        // Snapshots have no observer of their own; they ride along on every
        // full pass.
        if keys == nil {
            for source in AppSettings.currentEnabledSnapshots() {
                do {
                    queued += try await syncSnapshot(source)
                } catch {
                    anyFailed = true
                    await log.error("\(source.key): \(error.localizedDescription)")
                }
            }
        }
        if reimporting && !anyFailed && keys == nil {
            UserDefaults.standard.set(false, forKey: SettingsKeys.reimportPending)
            await log.info("full re-import pass completed for all enabled types")
        }
        let force: Bool
        switch reason {
        case .manual, .foreground, .settingsChanged, .reimport: force = true
        case .observer, .backgroundRefresh: force = false
        }
        await outbox.drain(force: force)
        await status.setSyncing(false)
        if queued > 0 {
            await log.info("sync (\(reason)): queued \(queued) sample(s)")
        }
    }

    private func cachedLatestHints() async -> [String: String]? {
        if let cached = latestFetch, Date().timeIntervalSince(cached.at) < Self.latestCacheInterval {
            return cached.hints
        }
        let hints = await latestHints()
        latestFetch = (Date(), hints)
        return hints
    }

    private func sync(_ type: SyncedType, anchor resolvedAnchor: HKQueryAnchor?, cutoffs: [String: Date]) async throws -> Int {
        var anchor = resolvedAnchor
        // Date-bounding a nil-anchor query skips the historical read while
        // still returning a store-wide anchor, so later incremental syncs
        // (which drop the predicate) see every subsequent change.
        var datePredicate: NSPredicate?
        if anchor == nil, let cutoff = cutoffs[type.key] {
            datePredicate = HKQuery.predicateForSamples(withStart: cutoff, end: nil)
            await log.info("\(type.key): server has history — backfilling only from \(cutoff.formatted(.iso8601))")
        }
        var queued = 0
        while true {
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.sample(type: type.sampleType, predicate: datePredicate)],
                anchor: anchor,
                limit: type.queryLimit
            )
            let result = try await descriptor.result(for: healthStore)
            let added = result.addedSamples
            let deleted = result.deletedObjects.map { $0.uuid.uuidString }
            let newAnchor = normalize(result.newAnchor)

            if added.isEmpty && deleted.isEmpty {
                // Nothing new — the anchor covers no undelivered samples, so
                // persisting it immediately is safe.
                if let newAnchor {
                    anchorCache[type.key] = newAnchor
                    anchors.save(newAnchor, for: type.key)
                }
                await status.recordChecked(type.key)
                return queued
            }

            var dtos: [SampleDTO] = []
            dtos.reserveCapacity(added.count)
            for sample in added {
                guard let dto = type.serialize(sample, .live) else { continue }
                // A failed enrich query throws out of the pass: the anchor
                // stays put and these samples are read again next time.
                dtos.append(try await type.enrich?(queries, dto, sample) ?? dto)
            }
            if dtos.count < added.count {
                await log.warn("\(type.key): \(added.count - dtos.count) sample(s) not serializable — skipped")
            }
            var elements = dtos.map(BatchElement.sample)
            if !deleted.isEmpty {
                elements.append(.tombstone(deleted))
            }
            let anchorData = newAnchor.flatMap { anchors.archive($0) }
            try await outbox.enqueue(typeKey: type.key, elements: elements, anchor: anchorData)
            if let newAnchor {
                anchorCache[type.key] = newAnchor
                anchor = newAnchor
            }
            queued += dtos.count
            await status.recordChecked(type.key)
            if !deleted.isEmpty {
                await log.info("\(type.key): queued \(dtos.count) sample(s) + \(deleted.count) deletion(s)")
            } else {
                await log.info("\(type.key): queued \(dtos.count) sample(s)")
            }
            if added.count < type.queryLimit && deleted.count < type.queryLimit {
                return queued
            }
        }
    }

    /// Reads a snapshot source and queues new versions of the records whose
    /// content changed (see SnapshotState). The state is saved once the
    /// batch is on disk, like an anchor once its samples are queued.
    private func syncSnapshot(_ source: SnapshotSource) async throws -> Int {
        let known = snapshotCache[source.key]
            ?? anchors.loadRaw(source.key).flatMap { try? JSONDecoder().decode(SnapshotState.self, from: $0) }
        let records = try await source.read(queries, .live, known?.fingerprints)
        var state = known ?? .fresh()
        let (send, superseded) = state.apply(records, complete: source.complete)
        await status.recordChecked(source.key)
        let encoded = try JSONEncoder().encode(state)
        guard !send.isEmpty || !superseded.isEmpty else {
            if known == nil { anchors.saveRaw(encoded, for: source.key) }
            return 0
        }
        var elements = send.map(BatchElement.sample)
        if !superseded.isEmpty {
            elements.append(.tombstone(superseded))
        }
        // Reserve the new versions durably first: the batch and the state
        // are two writes, and a crash between them must not reuse a uuid.
        anchors.saveRaw(try JSONEncoder().encode(state.reservation(committed: known)), for: source.key)
        try await outbox.enqueue(typeKey: source.key, elements: elements, anchor: nil)
        anchors.saveRaw(encoded, for: source.key)
        snapshotCache[source.key] = state
        await log.info("\(source.key): queued \(send.count) new version(s), \(superseded.count) superseded")
        return send.count
    }

    /// The SDK has flip-flopped on the optionality of `newAnchor`; funneling
    /// it through an optional parameter compiles either way.
    private func normalize(_ anchor: HKQueryAnchor?) -> HKQueryAnchor? {
        anchor
    }

    func resetAllAnchors() {
        anchorCache = [:]
        snapshotCache = [:]
        authBlocked = []
        latestFetch = nil
    }
}
