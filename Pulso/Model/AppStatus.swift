import Foundation
import Observation

struct DestinationStatus: Codable, Equatable, Sendable {
    var pending = 0
    var nextRetry: Date?
    var lastResponse: String?
    var lastSuccess: Date?
    var lastFailure: Date?
    var delivered = 0
}

struct TypeStatus: Codable, Equatable, Sendable {
    var lastChecked: Date?
    var lastDelivered: Date?
    var totalDelivered: Int = 0
}

/// Observable UI state. All mutation happens on the main actor; background
/// actors call the methods below with await.
@Observable
@MainActor
final class AppStatus {
    var healthUnavailable = false
    var authNeeded = false
    var syncing = false
    var needsInitialImport = false
    var typeStatus: [String: TypeStatus] = [:]
    var outboxPending = 0
    var outboxNextRetry: Date?
    var lastResponse: String?
    var recentLog: [LogEntry] = []
    var destinationStatus: [UUID: DestinationStatus] = [:]
    var lastSyncStarted: Date?
    var lastSyncFinished: Date?
    var lastSyncSummary: String?

    private static let statusKey = "status.types"
    private static let responseKey = "status.lastResponse"
    private static let destinationsKey = "status.destinations"
    private static let lastSyncKey = "status.lastSync"
    private let maxLogEntries = 200

    func load() {
        if let data = UserDefaults.standard.data(forKey: Self.statusKey),
           let decoded = try? JSONDecoder().decode([String: TypeStatus].self, from: data) {
            typeStatus = decoded
        }
        lastResponse = UserDefaults.standard.string(forKey: Self.responseKey)
        if let data = UserDefaults.standard.data(forKey: Self.destinationsKey),
           let decoded = try? JSONDecoder().decode([UUID: DestinationStatus].self, from: data) {
            destinationStatus = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.lastSyncKey),
           let decoded = try? JSONDecoder().decode(LastSync.self, from: data) {
            lastSyncStarted = decoded.started
            lastSyncFinished = decoded.finished
            lastSyncSummary = decoded.summary
        }
    }

    /// Persisted so App Intents (which may run with the UI never shown)
    /// and the next launch see the same answer.
    struct LastSync: Codable, Sendable {
        var started: Date?
        var finished: Date?
        var summary: String?
    }

    nonisolated static func storedLastSync() -> LastSync? {
        UserDefaults.standard.data(forKey: lastSyncKey).flatMap { try? JSONDecoder().decode(LastSync.self, from: $0) }
    }

    nonisolated static func storedDestinationStatus() -> [UUID: DestinationStatus] {
        UserDefaults.standard.data(forKey: destinationsKey)
            .flatMap { try? JSONDecoder().decode([UUID: DestinationStatus].self, from: $0) } ?? [:]
    }

    func recordSyncStarted() {
        lastSyncStarted = Date()
        saveLastSync()
    }

    func recordSyncFinished(_ summary: String) {
        lastSyncFinished = Date()
        lastSyncSummary = summary
        saveLastSync()
    }

    private func saveLastSync() {
        let value = LastSync(started: lastSyncStarted, finished: lastSyncFinished, summary: lastSyncSummary)
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.lastSyncKey)
        }
    }

    func recordDestinationDelivery(_ id: UUID, count: Int, response: String) {
        updateDestination(id) {
            $0.lastSuccess = Date()
            $0.lastResponse = response
            $0.delivered += count
        }
    }

    func recordDestinationFailure(_ id: UUID, response: String) {
        updateDestination(id) {
            $0.lastFailure = Date()
            $0.lastResponse = response
        }
    }

    func setDestinationOutbox(_ id: UUID, pending: Int, nextRetry: Date?) {
        updateDestination(id) {
            $0.pending = pending
            $0.nextRetry = nextRetry
        }
    }

    private func updateDestination(_ id: UUID, _ mutate: (inout DestinationStatus) -> Void) {
        var value = destinationStatus[id] ?? DestinationStatus()
        mutate(&value)
        destinationStatus[id] = value
        if let data = try? JSONEncoder().encode(destinationStatus) {
            UserDefaults.standard.set(data, forKey: Self.destinationsKey)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(typeStatus) {
            UserDefaults.standard.set(data, forKey: Self.statusKey)
        }
        UserDefaults.standard.set(lastResponse, forKey: Self.responseKey)
    }

    func setSyncing(_ value: Bool) {
        syncing = value
    }

    func recordChecked(_ key: String) {
        update(key) { $0.lastChecked = Date() }
    }

    func recordDelivery(typeKey: String, count: Int, response: String) {
        update(typeKey) {
            $0.lastDelivered = Date()
            $0.totalDelivered += count
        }
        lastResponse = response
        save()
    }

    func setLastResponse(_ response: String) {
        lastResponse = response
        save()
    }

    func setOutbox(pending: Int, nextRetry: Date?) {
        outboxPending = pending
        outboxNextRetry = nextRetry
    }

    func resetCounters() {
        typeStatus = [:]
        destinationStatus = destinationStatus.mapValues { status in
            var reset = DestinationStatus()
            reset.pending = status.pending
            return reset
        }
        lastResponse = nil
        save()
    }

    func push(_ entry: LogEntry) {
        recentLog.insert(entry, at: 0)
        if recentLog.count > maxLogEntries {
            recentLog.removeLast(recentLog.count - maxLogEntries)
        }
    }

    func seedLog(_ entries: [LogEntry]) {
        recentLog = entries.sorted { $0.date > $1.date }
    }

    private func update(_ key: String, _ mutate: (inout TypeStatus) -> Void) {
        var status = typeStatus[key] ?? TypeStatus()
        mutate(&status)
        typeStatus[key] = status
        save()
    }
}
