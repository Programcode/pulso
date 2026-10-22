import Foundation

/// One Outbox per destination, each in its own folder. A batch is written
/// to every enabled destination's queue before enqueue returns; each queue
/// then drains on its own schedule, so a destination that is down only
/// delays itself.
actor OutboxHub {
    enum EnqueueError: LocalizedError {
        case noDestination
        /// The receiving destinations changed since the catch-up hints were
        /// fetched; the batch would skip history a new destination needs.
        case destinationsChanged

        var errorDescription: String? {
            switch self {
            case .noDestination: "no enabled destination is configured"
            case .destinationsChanged: "destinations changed during catch-up"
            }
        }
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

    private func outbox(for destination: Destination) -> Outbox {
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
            // Per-type counts follow the first deliverable destination,
            // decided per batch so removing it hands the role on.
            countsTowardTypes: { destinations().first { $0.enabled && $0.isConfigured }?.id == id }
        )
        outboxes[id] = outbox
        return outbox
    }

    /// Every destination that receives batches, configured right now or
    /// not: one whose URL is being edited keeps queueing and delivers once
    /// it is valid again, instead of missing the batches synced meanwhile.
    private var active: [(destination: Destination, outbox: Outbox)] {
        destinations().filter(\.receivesBatches).map { ($0, outbox(for: $0)) }
    }

    /// True when at least one destination can deliver right now.
    func hasActiveDestination() -> Bool {
        destinations().contains { $0.enabled && $0.isConfigured }
    }

    /// Writes the elements to every enabled destination's queue. Throws if
    /// none can deliver or a write fails, in which case the caller must not
    /// advance its anchor.
    /// With `catchUpKey`, refuses unless the destinations written to are
    /// exactly the set the catch-up hints came from (checked against the
    /// same list it writes to).
    func enqueue(typeKey: String, elements: [BatchElement], catchUpKey: String? = nil) async throws {
        // Every decision comes from this one snapshot: a second read could
        // see a deliverable destination this list doesn't write to.
        let targets = active
        guard targets.contains(where: { $0.destination.isConfigured }) else { throw EnqueueError.noDestination }
        if let catchUpKey, AppSettings.catchUpKey(targets.map(\.destination)) != catchUpKey {
            throw EnqueueError.destinationsChanged
        }
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
