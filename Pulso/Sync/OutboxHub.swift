import Foundation

/// One Outbox per destination, each in its own folder. A batch is written
/// to every enabled destination's queue before enqueue returns; each queue
/// then drains on its own schedule, so a destination that is down only
/// delays itself.
actor OutboxHub {
    enum EnqueueError: LocalizedError {
        case noDestination

        var errorDescription: String? { "no enabled destination is configured" }
    }

    private let root: URL
    private let log: LogStore
    private let status: AppStatus
    private let maxBatchBytes: Int
    private let destinations: @Sendable () -> [Destination]
    private let makeTransport: @Sendable (Destination) -> Transport?
    private var outboxes: [UUID: Outbox] = [:]

    init(
        root: URL, log: LogStore, status: AppStatus,
        maxBatchBytes: Int = Wire.maxBatchBytes,
        destinations: @escaping @Sendable () -> [Destination] = { AppSettings.currentDestinations() },
        transport: @escaping @Sendable (Destination) -> Transport? = { $0.transport }
    ) {
        self.root = root
        self.log = log
        self.status = status
        self.maxBatchBytes = maxBatchBytes
        self.destinations = destinations
        makeTransport = transport
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func outbox(for destination: Destination, primary: Bool) -> Outbox {
        if let existing = outboxes[destination.id] { return existing }
        let id = destination.id
        let destinations = destinations
        let makeTransport = makeTransport
        let outbox = Outbox(
            directory: root.appendingPathComponent(id.uuidString, isDirectory: true),
            anchors: nil,
            label: destination.name,
            // Resolved at send time so edits (URL, token, …) apply to
            // batches already queued.
            transport: { destinations().first { $0.id == id && $0.enabled }.flatMap(makeTransport) },
            log: log,
            status: status,
            maxBatchBytes: maxBatchBytes,
            maxItems: destination.maxItemsPerBatch,
            destinationID: id,
            countsTowardTypes: primary
        )
        outboxes[id] = outbox
        return outbox
    }

    private var active: [(destination: Destination, outbox: Outbox)] {
        let enabled = destinations().filter { $0.enabled && $0.isConfigured }
        return enabled.enumerated().map { index, destination in
            (destination, outbox(for: destination, primary: index == 0))
        }
    }

    /// True when at least one destination would receive a batch.
    func hasActiveDestination() -> Bool {
        !active.isEmpty
    }

    /// Writes the elements to every active destination's queue. Throws if
    /// there is none or a write fails, in which case the caller must not
    /// advance its anchor.
    func enqueue(typeKey: String, elements: [BatchElement]) async throws {
        let targets = active
        guard !targets.isEmpty else { throw EnqueueError.noDestination }
        for target in targets {
            try await target.outbox.enqueue(typeKey: typeKey, elements: elements, anchor: nil)
        }
    }

    func drain(force: Bool) async {
        let targets = active.map(\.outbox)
        await withTaskGroup(of: Void.self) { group in
            for outbox in targets {
                group.addTask { await outbox.drain(force: force) }
            }
        }
    }

    func drain(destination id: UUID, force: Bool) async {
        guard let target = active.first(where: { $0.destination.id == id }) else { return }
        await target.outbox.drain(force: force)
    }

    func pendingCount() async -> Int {
        var total = 0
        for target in active {
            total += await target.outbox.pendingCount()
        }
        return total
    }

    func refreshPendingStatus() async {
        for target in active {
            await target.outbox.refreshPendingStatus()
        }
        await status.setOutbox(pending: await pendingCount(), nextRetry: nil)
    }

    func removeAll() async {
        for target in active {
            await target.outbox.removeAll()
        }
    }

    /// Drops the queue of a destination that was deleted.
    func forget(_ id: UUID) {
        outboxes[id] = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }
}
