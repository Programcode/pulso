import BackgroundTasks
import HealthKit
import UIKit

/// Registers every sanctioned wake mechanism and funnels them all into
/// SyncEngine.requestSync: HealthKit observer queries with background
/// delivery (primary), BGAppRefreshTask (opportunistic backstop), and the
/// foreground hook (wired via AppServices.scenePhase).
@MainActor
final class TriggerHub {
    /// Fixed rather than derived from the bundle id: Info.plist lists it
    /// verbatim, and a re-signed build may run under a different bundle id.
    static let refreshTaskID = "pulso.refresh"
    static let processingTaskID = "pulso.processing"

    private let healthStore: HKHealthStore
    private let engine: SyncEngine
    private let log: LogStore
    private var observerQueries: [HKObserverQuery] = []

    init(healthStore: HKHealthStore, engine: SyncEngine, log: LogStore) {
        self.healthStore = healthStore
        self.engine = engine
        self.log = log
    }

    // MARK: - BGAppRefreshTask

    /// Must run before application(_:didFinishLaunchingWithOptions:) returns.
    func registerBackgroundTasks() {
        registerBackgroundRefresh()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskID, using: nil) { [weak self] task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.handleProcessing(processing)
            }
        }
    }

    // MARK: - BGProcessingTask

    /// A longer background window (typically overnight, on power) for
    /// catching up and draining queues that a refresh couldn't finish.
    private func handleProcessing(_ task: BGProcessingTask) {
        scheduleProcessing()
        let work = Task {
            await log.info("background processing fired")
            await engine.requestSync(.processing)
            if !Task.isCancelled {
                task.setTaskCompleted(success: true)
            }
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(request) // unsupported on simulator; fine
    }

    private func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.handleRefresh(refresh)
            }
        }
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleNextRefresh()
        let work = Task {
            await log.info("background refresh fired")
            await engine.requestSync(.backgroundRefresh)
            if !Task.isCancelled {
                task.setTaskCompleted(success: true)
            }
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request) // unsupported on simulator; fine
    }

    // MARK: - Observer queries

    /// (Re)registers background delivery and one observer query covering
    /// every enabled type. Called at launch and when toggles change.
    func startObservers() async {
        stopObservers()
        let refused = HealthAuthorization.lastRejected()
        var descriptors: [HKQueryDescriptor] = []
        var unavailable: [String] = []
        for type in TypeRegistry.all {
            guard AppSettings.currentEnabled(type.key), !refused.contains(type.sampleType.identifier) else {
                try? await healthStore.disableBackgroundDelivery(for: type.sampleType)
                continue
            }
            // Only types in the main read set share the observer: one the app
            // can't observe (a correlation, a type shared object by object)
            // would fail the whole query. Full passes pick those up.
            guard type.access == .read else { continue }
            do {
                try await healthStore.enableBackgroundDelivery(for: type.sampleType, frequency: type.frequency)
            } catch {
                unavailable.append(type.key)
            }
            descriptors.append(HKQueryDescriptor(sampleType: type.sampleType, predicate: nil))
        }
        if !unavailable.isEmpty {
            await log.warn("background delivery unavailable for \(unavailable.count) type(s): \(unavailable.prefix(15).joined(separator: ", "))")
        }
        guard !descriptors.isEmpty else { return }
        let query = HKObserverQuery(queryDescriptors: descriptors) { [weak self] _, changed, completionHandler, error in
            if error != nil {
                completionHandler()
                return
            }
            let keys = Set((changed ?? []).compactMap { TypeRegistry.type(for: $0)?.key })
            Task { @MainActor [weak self] in
                // HealthKit throttles future deliveries if the completion
                // handler is called before the work is done — so it is
                // called after the sync pass, from a background task with
                // a watchdog in case the server hangs.
                guard let self else {
                    completionHandler()
                    return
                }
                await self.observerFired(keys)
                completionHandler()
            }
        }
        healthStore.execute(query)
        observerQueries.append(query)
        await log.info("observing \(descriptors.count) type(s) for background delivery")
    }

    func stopObservers() {
        observerQueries.forEach(healthStore.stop)
        observerQueries.removeAll()
    }

    private func observerFired(_ keys: Set<String>) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pulso-observer-sync")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        let label = keys.count == 1 ? keys.first! : "\(keys.count) types"
        if UIApplication.shared.isProtectedDataAvailable {
            await log.info("observer wake: \(label)")
        } else {
            // F2: health data is unreadable while locked. The attempt is
            // still made — it fails cleanly without moving anchors — and the
            // next unlock-time trigger catches up.
            await log.info("observer wake (\(label)) while device locked — will catch up after unlock")
        }
        let engine = engine
        // An empty set (HealthKit didn't say which types) means a full pass.
        let only = keys.isEmpty ? nil : keys
        await withTimeout(seconds: 25) {
            await engine.requestSync(.observer(label), only: only)
        }
    }
}

/// Runs an operation but returns after `seconds` even if it hasn't finished,
/// cancelling it. Used to guarantee observer completion handlers are called
/// within the background execution window.
func withTimeout(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        await group.next()
        group.cancelAll()
    }
}
