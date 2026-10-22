import Foundation
import HealthKit
import SwiftUI

/// Composition root: owns the four components and the lifecycle glue.
@MainActor
final class AppServices {
    /// One instance per process, shared by the app delegate and App
    /// Intents (which can run with no UI shown).
    static let shared = AppServices()

    let healthStore = HKHealthStore()
    let settings = AppSettings()
    let status = AppStatus()
    let log: LogStore
    let anchors: AnchorStore
    let outbox: OutboxHub
    let engine: SyncEngine
    let hub: TriggerHub
    private let uploader = HTTPUploader()

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fm.temporaryDirectory
        var root = support.appendingPathComponent("Pulso", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Pending health data must not leak into device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)

        log = LogStore(directory: root)
        anchors = AnchorStore(directory: root.appendingPathComponent("Anchors", isDirectory: true))
        let queues = root.appendingPathComponent("Outboxes", isDirectory: true)
        Self.adoptLegacyOutbox(from: root.appendingPathComponent("Outbox", isDirectory: true), into: queues)
        outbox = OutboxHub(root: queues, log: log, status: status)
        let uploader = uploader
        engine = SyncEngine(
            healthStore: healthStore, anchors: anchors, outbox: outbox, log: log, status: status,
            latestHints: {
                // The anchor is shared, so skipping history is only safe when
                // every destination already has it: all must answer, and the
                // earliest answer per type wins.
                let destinations = AppSettings.receivingDestinations()
                guard !destinations.isEmpty, destinations.allSatisfy({ $0.latestURL != nil }) else { return nil }
                var answers: [[String: String]] = []
                for destination in destinations {
                    guard let url = destination.latestURL,
                          let hints = await uploader.fetchLatest(url: url, token: destination.bearerToken) else { return nil }
                    answers.append(hints)
                }
                return CatchUp.earliest(answers)
            }
        )
        hub = TriggerHub(healthStore: healthStore, engine: engine, log: log)

        status.load()
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary ?? [:]
        DeviceInfo.current = DeviceInfo(
            id: device.identifierForVendor?.uuidString ?? "unknown",
            name: device.name,
            model: device.model,
            systemVersion: device.systemVersion,
            appVersion: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            bundleId: Bundle.main.bundleIdentifier ?? ""
        )
        let status = status
        let log = log
        Task {
            let entries = await log.tail(200)
            status.seedLog(entries)
            await log.setSink { entry in
                Task { @MainActor in status.push(entry) }
            }
        }
    }

    /// Batches queued by the single-server version belong to the migrated
    /// "Pulso server" destination.
    private static func adoptLegacyOutbox(from legacy: URL, into queues: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        // Without a migrated server there is nowhere to deliver them yet:
        // leave the folder alone rather than lose queued data.
        guard let destination = AppSettings.currentDestinations().first(where: { $0.kind == .pulso }) else { return }
        // Never move a queue's sequence backwards, or new batches would sort
        // ahead of ones already waiting.
        let defaults = UserDefaults.standard
        let sequenceKey = "\(SettingsKeys.outboxSequence).\(destination.id.uuidString)"
        defaults.set(
            max(defaults.integer(forKey: SettingsKeys.outboxSequence), defaults.integer(forKey: sequenceKey)),
            forKey: sequenceKey
        )
        do {
            let target = queues.appendingPathComponent(destination.id.uuidString, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "json" {
                try fm.moveItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
            }
        } catch {
            return // whatever didn't move stays put; the next launch tries again
        }
        try? fm.removeItem(at: legacy)
    }

    private var isTestRun: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var launched = false

    /// Called from application(_:didFinishLaunchingWithOptions:). Also runs
    /// when HealthKit relaunches the app in the background for delivery.
    func launch() {
        guard !launched else { return }
        launched = true
        guard HKHealthStore.isHealthDataAvailable() else {
            status.healthUnavailable = true
            return
        }
        guard !isTestRun else { return }
        hub.registerBackgroundTasks()
        hub.scheduleNextRefresh()
        hub.scheduleProcessing()
        Task {
            await refreshAuthStatus()
            await hub.startObservers()
            await refreshDerived()
        }
    }

    func scenePhase(_ phase: ScenePhase) {
        guard !isTestRun, !status.healthUnavailable else { return }
        switch phase {
        case .active:
            Task {
                await refreshAuthStatus()
                await syncNow(.foreground)
            }
        case .background:
            hub.scheduleNextRefresh()
            hub.scheduleProcessing()
        default:
            break
        }
    }

    func syncNow(_ reason: SyncReason = .manual) async {
        // Backfill can take a while; don't let the screen lock kill it (F2).
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        await engine.requestSync(reason)
        await refreshDerived()
    }

    /// The read set this OS accepts, probed once per launch (cheap, no UI).
    private lazy var readSet: HealthAuthorization.ReadSet = {
        let set = HealthAuthorization.readSet(TypeRegistry.readTypes, store: healthStore)
        let log = log
        let rejected = set.rejected
        Task {
            await log.info("Health read set: \(set.accepted.count) type(s) accepted")
            for (identifier, reason) in rejected.sorted(by: { $0.key < $1.key }) {
                await log.warn("HealthKit refuses read access to \(identifier) on this iOS — skipped (\(reason.prefix(160)))")
            }
        }
        return set
    }()

    func requestHealthAccess() async {
        do {
            try await HealthAuthorization.request(readSet.accepted, store: healthStore)
        } catch {
            await log.error("authorization request failed: \(error.localizedDescription)")
        }
        await refreshAuthStatus()
        await syncNow(.manual)
    }

    /// Vision prescriptions and medications are shared object by object:
    /// HealthKit shows its own picker, which needs a user tap to open.
    func requestPerObjectAccess(_ key: String) async {
        guard let entry = TypeRegistry.perObjectTypes.first(where: { $0.key == key }) else { return }
        do {
            try await healthStore.requestPerObjectReadAuthorization(for: entry.type, predicate: nil)
            await log.info("\(key): per-object access updated")
        } catch {
            await log.error("\(key): per-object access failed: \(error.localizedDescription)")
        }
        await syncNow(.manual)
    }

    func refreshAuthStatus() async {
        guard !status.healthUnavailable else { return }
        do {
            let request = try await HealthAuthorization.requestStatus(readSet.accepted, store: healthStore)
            status.authNeeded = request == .shouldRequest
        } catch {
            // Typically a signing problem (missing HealthKit entitlement) —
            // surface it, and keep the last known authNeeded rather than
            // clearing it: hiding the Grant button on a transient error
            // would strand newly added types with no way to authorize them.
            await log.warn("could not determine Health authorization status: \(error.localizedDescription)")
        }
    }

    func refreshDerived() async {
        let refused = HealthAuthorization.lastRejected()
        let pendingKeys = AppSettings.currentEnabledTypes()
            .filter { !refused.contains($0.sampleType.identifier) }
            .map(\.key) + AppSettings.currentEnabledSnapshots().map(\.key)
        status.needsInitialImport = pendingKeys.contains { !anchors.hasAnchor($0) }
        await outbox.refreshPendingStatus()
    }

    func typeTogglesChanged() {
        Task {
            await hub.startObservers()
            await engine.requestSync(.settingsChanged)
            await refreshDerived()
        }
    }

    /// Clears all sync state and re-sends everything. Safe (the server
    /// dedupes by uuid) but slow — guarded by a confirmation in Settings.
    /// Uses .reimport so the server catch-up shortcut is bypassed; if the
    /// pass is interrupted, tap Re-import again to restart it.
    func reimportAll() async {
        // Durable flag first: any pass that runs from here on (including an
        // interleaved observer pass, or a resumed pass after the app is
        // killed mid-import) must not take the catch-up shortcut.
        UserDefaults.standard.set(true, forKey: SettingsKeys.reimportPending)
        await log.warn("full re-import requested — clearing anchors and outbox")
        await outbox.removeAll()
        anchors.clearAll()
        await engine.resetAllAnchors()
        status.resetCounters()
        await syncNow(.reimport)
    }

    // MARK: - Shortcuts

    /// Intents may run before the delegate did (or in a process HealthKit
    /// woke); launching twice is a no-op.
    func launchIfNeeded() {
        launch()
    }

    func syncFromIntent(keys: Set<String>?) async -> String {
        await withBackgroundTime("pulso-shortcut-sync") {
            await engine.requestSync(.intent("Sync Health Data"), only: keys)
        }
        await refreshDerived()
        return status.lastSyncSummary ?? "Sync finished."
    }

    func resend(keys: Set<String>?, start: Date?, end: Date?, reason: SyncReason) async -> String {
        var summary = ""
        await withBackgroundTime("pulso-shortcut-resend") {
            summary = await engine.resend(only: keys, start: start, end: end, reason: reason)
        }
        await refreshDerived()
        return summary
    }

    func statusReport() async -> String {
        await outbox.refreshPendingStatus()
        var lines: [String] = []
        if let finished = status.lastSyncFinished {
            lines.append("Last sync finished \(finished.formatted(date: .abbreviated, time: .shortened)).")
        } else {
            lines.append("No sync has finished yet.")
        }
        if let summary = status.lastSyncSummary { lines.append(summary) }
        for destination in settings.destinations where destination.enabled {
            let state = status.destinationStatus[destination.id] ?? DestinationStatus()
            var line = "\(destination.name): \(state.pending) batch(es) queued"
            if let success = state.lastSuccess {
                line += ", last delivery \(success.formatted(date: .abbreviated, time: .shortened))"
            }
            if let failure = state.lastFailure, failure > (state.lastSuccess ?? .distantPast), let response = state.lastResponse {
                line += ", failing: \(response)"
            }
            lines.append(line + ".")
        }
        if settings.destinations.allSatisfy({ !$0.enabled }) {
            lines.append("No destination is enabled.")
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the process alive while a shortcut's work runs in the background.
    private func withBackgroundTime(_ name: String, _ work: () async -> Void) async {
        // Ended either when the work finishes or when iOS says time is up,
        // whichever comes first; an outstanding assertion gets the app killed.
        final class Assertion: @unchecked Sendable {
            private let lock = NSLock()
            private var id: UIBackgroundTaskIdentifier = .invalid
            func set(_ value: UIBackgroundTaskIdentifier) { lock.lock(); id = value; lock.unlock() }
            func end() {
                lock.lock()
                let current = id
                id = .invalid
                lock.unlock()
                if current != .invalid { UIApplication.shared.endBackgroundTask(current) }
            }
        }
        let assertion = Assertion()
        assertion.set(UIApplication.shared.beginBackgroundTask(withName: name) { assertion.end() })
        await work()
        assertion.end()
    }

    // MARK: - Destinations

    func destinationsChanged() {
        Task {
            await outbox.refreshPendingStatus()
        }
    }

    func removeDestination(_ destination: Destination) {
        settings.destinations.removeAll { $0.id == destination.id }
        destination.deleteSecrets()
        Task { await outbox.forget(destination.id) }
    }

    /// Sends something harmless the destination must accept: an empty test
    /// batch over HTTP (signed and authenticated like real ones), a message
    /// on <prefix>/test over MQTT, a small file for file export.
    func testDestination(_ destination: Destination) async -> String {
        do {
            switch destination.kind {
            case .pulso:
                guard let base = AppSettings.baseURL(from: destination.url),
                      let url = URL(string: base.absoluteString + "/health") else { return "Enter a valid URL first" }
                return await uploader.checkHealth(url)
            case .rest, .homeAssistant:
                let transport = HTTPTransport(destination: destination, session: HTTPTransport.makeSession())
                let format: Destination.BodyFormat = destination.kind == .homeAssistant ? .envelope : destination.format
                let result = try await transport.post(try BatchBody.test(device: DeviceInfo.current, format: format))
                return result.isSuccess
                    ? "OK — HTTP \(result.status)"
                    : "HTTP \(result.status): \(result.bodySnippet.prefix(120))"
            case .mqtt:
                try await MQTTTransport(destination: destination).test()
                return "OK — published to \(MQTTTransport(destination: destination).topic("test"))"
            case .file:
                try FileTransport(destination: destination).test()
                return "OK — wrote pulso-test.txt"
            }
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}
