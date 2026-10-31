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
            latestHints: { destinations in
                // The anchor is shared, so skipping history is only safe when
                // every destination already has it: all must answer, and the
                // earliest answer per type wins.
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
                if settings.syncAll && status.authNeeded && !autoRequestedAccess {
                    // Types this build reads that HealthKit has never asked
                    // about: one sheet covers them. Once per launch, since a
                    // dismissed sheet leaves them unasked.
                    autoRequestedAccess = true
                    await log.info("sync all: asking for Health types not requested yet")
                    await requestHealthAccess() // syncs afterwards
                } else {
                    await syncNow(.foreground)
                }
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

    private var autoRequestedAccess = false

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

    /// Turning the mode on enables every type at once, so it also asks for
    /// any HealthKit hasn't been asked about; turning it off restores the
    /// saved per-type selection.
    func setSyncAll(_ on: Bool) {
        settings.syncAll = on
        Task {
            await hub.startObservers()
            await refreshAuthStatus()
            if on && status.authNeeded {
                autoRequestedAccess = true
                await requestHealthAccess() // syncs afterwards
            } else {
                await engine.requestSync(.settingsChanged)
                await refreshDerived()
            }
        }
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
        // Otherwise the pass returns early and the shortcut would report the
        // previous sync's summary as if this one had run.
        guard await outbox.hasActiveDestination() else { return "No destination is configured." }
        await withBackgroundTime("pulso-shortcut-sync") {
            await engine.requestSync(.intent("Sync Health Data"), only: keys)
        }
        await refreshDerived()
        return status.lastSyncSummary ?? "Sync finished."
    }

    /// Background time a shortcut gets isn't documented; about 30 seconds
    /// is what's observed, so the work stops waiting a little before.
    static let shortcutBudget: TimeInterval = 25

    /// The Sync All Health Data shortcut: every type this build reads,
    /// whatever the toggles say, within a shortcut's background time. Made
    /// to run from automations, so it never asks anything; problems it
    /// can't work around are thrown with what to do about them.
    func syncAllFromIntent() async throws -> String {
        guard HKHealthStore.isHealthDataAvailable(), !status.healthUnavailable else {
            throw IntentFailure("Apple Health isn't available on this device.")
        }
        guard await outbox.hasActiveDestination() else {
            throw IntentFailure("No destination is set up. Add one in Pulso → Settings → Destinations.")
        }
        let engine = engine
        let outbox = outbox
        // Health data can't be read while the phone is locked, which is
        // when timed automations often run. Queued batches can still go out;
        // a message rather than an error keeps scheduled runs quiet.
        guard UIApplication.shared.isProtectedDataAvailable else {
            await withBackgroundTime("pulso-shortcut-sync-all") {
                _ = await withTimeout(seconds: Self.shortcutBudget) { await outbox.drain(force: true) }
            }
            let pending = await outbox.pendingCount()
            await log.info("shortcut: Sync All Health Data ran while locked")
            return "iPhone locked: Health data can't be read until it's unlocked. "
                + (pending == 0 ? "Nothing is waiting to be sent." : "\(pending) batch(es) still waiting to be sent.")
        }
        await refreshAuthStatus()
        var result: SyncOutcome??
        await withBackgroundTime("pulso-shortcut-sync-all") {
            result = await withTimeout(seconds: Self.shortcutBudget) {
                await engine.requestSync(.intent("Sync All Health Data"), allTypes: true)
            }
        }
        await refreshDerived()
        guard let outcome = result ?? nil else {
            return "Still syncing after \(Int(Self.shortcutBudget)) seconds (a first import takes a while). "
                + "Progress is saved; the next run carries on."
        }
        let succeeded = outcome.attempted - outcome.failed.count
        if succeeded == 0 && outcome.attempted > 0 {
            if status.authNeeded {
                throw IntentFailure("Pulso has no Health access yet. Open Pulso and tap Grant Health Access.")
            }
            throw IntentFailure("Every Health type failed to read. Open Pulso → Activity Log for details.")
        }
        var parts = ["Checked \(outcome.attempted) types, queued \(outcome.queued.formatted()) new sample(s)."]
        parts.append(outcome.pending == 0 ? "All delivered." : "\(outcome.pending) batch(es) waiting to be retried.")
        if status.authNeeded {
            parts.append("Some types need Health access: open Pulso once.")
        } else if !outcome.failed.isEmpty {
            parts.append("\(outcome.failed.count) failed: \(outcome.failed.prefix(3).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
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
