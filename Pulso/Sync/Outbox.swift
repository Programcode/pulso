import Foundation

/// Durable delivery queue for one destination. Every batch is written to
/// disk *before* the first delivery attempt and deleted only once the
/// destination accepts it (a 2xx, a broker PUBACK, a completed file write).
/// Files drain strictly in enqueue order and draining stops at the first
/// failure. At-least-once delivery; receivers dedupe by sample uuid.
///
/// With `anchors`, a batch's anchor is persisted when it is accepted (the
/// original single-server design). OutboxHub passes nil: with several
/// destinations SyncEngine persists anchors once a batch is on disk in
/// every queue, so no destination can hold back another.
actor Outbox {
    static let baseRetryInterval: TimeInterval = 60
    static let maxRetryInterval: TimeInterval = 3600

    private let directory: URL
    private let anchors: AnchorStore?
    private let label: String
    private let transport: @Sendable () -> Transport?
    private let log: LogStore
    private let status: AppStatus
    private let maxBatchBytes: Int
    private let maxItems: Int?
    private let destinationID: UUID?
    /// Per-type delivery counts come from one destination only, or two
    /// destinations would double them.
    private let countsTowardTypes: Bool
    private let sequenceKey: String
    private var sequence: Int
    private var failureCount = 0
    private var nextAttempt = Date.distantPast
    private var chain: Task<Void, Never>?

    init(
        directory: URL,
        anchors: AnchorStore?,
        label: String = "outbox",
        transport: @escaping @Sendable () -> Transport?,
        log: LogStore,
        status: AppStatus,
        maxBatchBytes: Int = Wire.maxBatchBytes,
        maxItems: Int? = nil,
        destinationID: UUID? = nil,
        countsTowardTypes: Bool = true
    ) {
        self.directory = directory
        self.anchors = anchors
        self.label = label
        self.transport = transport
        self.log = log
        self.status = status
        self.maxBatchBytes = maxBatchBytes
        self.maxItems = maxItems
        self.destinationID = destinationID
        self.countsTowardTypes = countsTowardTypes
        sequenceKey = destinationID.map { "\(SettingsKeys.outboxSequence).\($0.uuidString)" } ?? SettingsKeys.outboxSequence
        sequence = UserDefaults.standard.integer(forKey: sequenceKey)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The original single-server shape: gzip the bare array and POST it.
    init(
        directory: URL,
        anchors: AnchorStore,
        uploader: Uploading,
        target: @escaping @Sendable () -> (url: URL, token: String?)?,
        log: LogStore,
        status: AppStatus,
        maxBatchBytes: Int = Wire.maxBatchBytes
    ) {
        self.init(
            directory: directory, anchors: anchors,
            transport: { target().map { LegacyUploadTransport(uploader: uploader, url: $0.url, token: $0.token) } },
            log: log, status: status, maxBatchBytes: maxBatchBytes
        )
    }

    // MARK: - Enqueue

    func enqueue(typeKey: String, elements: [BatchElement], anchor: Data?) throws {
        guard !elements.isEmpty else { return }
        var slices = try BatchSlicer.slice(elements, maxBytes: maxBatchBytes)
        if let maxItems {
            slices = slices.flatMap { slice in
                stride(from: 0, to: slice.count, by: maxItems).map { Array(slice[$0 ..< min($0 + maxItems, slice.count)]) }
            }
        }
        for (index, slice) in slices.enumerated() {
            let batch = Batch(
                id: UUID(),
                typeKey: typeKey,
                createdAt: Date(),
                anchor: index == slices.count - 1 ? anchor : nil,
                elements: slice
            )
            let data = try Wire.fileEncoder().encode(batch)
            sequence += 1
            UserDefaults.standard.set(sequence, forKey: sequenceKey)
            let name = String(format: "batch-%012d-%@.json", sequence, String(batch.id.uuidString.prefix(8)))
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        // Pipeline uploads with whatever the caller does next.
        Task { await self.drain(force: false) }
    }

    // MARK: - Drain

    /// Serialized via task-chaining: concurrent calls queue up rather than
    /// interleave, and every caller returns only after its own pass finished.
    func drain(force: Bool) async {
        let previous = chain
        let task = Task {
            await previous?.value
            await self.performDrain(force: force)
        }
        chain = task
        await task.value
    }

    private func performDrain(force: Bool) async {
        defer { Task { await self.refreshPendingStatus() } }
        var files = pendingFiles()
        guard !files.isEmpty else { return }
        guard let transport = transport() else {
            await log.info("\(label): \(files.count) batch(es) waiting — destination not configured")
            return
        }
        if !force && Date() < nextAttempt { return }

        while let file = files.first, !Task.isCancelled {
            files.removeFirst()
            let batch: Batch
            do {
                batch = try Wire.fileDecoder().decode(Batch.self, from: Data(contentsOf: file))
            } catch {
                // A batch file we can't read would poison the queue forever; set it aside.
                quarantine(file)
                await log.error("\(label): unreadable batch \(file.lastPathComponent) set aside (\(error.localizedDescription))")
                continue
            }
            do {
                let result = try await transport.deliver(batch)
                guard result.isSuccess else {
                    await recordFailure("HTTP \(result.status) \(result.bodySnippet.prefix(120))", status: result.status)
                    return
                }
                try? FileManager.default.removeItem(at: file)
                if let anchorData = batch.anchor {
                    anchors?.saveRaw(anchorData, for: batch.typeKey)
                }
                failureCount = 0
                nextAttempt = .distantPast
                let response = "\(result.status) · \(result.bodySnippet.prefix(80))"
                if countsTowardTypes {
                    await status.recordDelivery(typeKey: batch.typeKey, count: batch.sampleCount, response: response)
                }
                if let destinationID {
                    await status.recordDestinationDelivery(destinationID, count: batch.sampleCount, response: response)
                }
                await log.info(
                    "\(label): delivered \(batch.sampleCount) \(batch.typeKey) sample(s) — \(result.status) in \(Int(result.duration * 1000))ms"
                )
            } catch {
                await recordFailure(error.localizedDescription, status: nil)
                return
            }
        }
    }

    private func recordFailure(_ reason: String, status statusCode: Int?) async {
        failureCount += 1
        let delay = min(
            Self.maxRetryInterval,
            Self.baseRetryInterval * pow(2, Double(failureCount - 1))
        )
        nextAttempt = Date(timeIntervalSinceNow: delay)
        var hint = ""
        if statusCode == 401 { hint = " — check the token / signature secret in Settings" }
        let text = String(reason.prefix(160))
        if let destinationID {
            await status.recordDestinationFailure(destinationID, response: text)
        }
        if countsTowardTypes {
            await status.setLastResponse(text)
        }
        await log.warn("\(label): delivery failed: \(reason)\(hint) — retrying in \(Int(delay))s")
    }

    private func quarantine(_ file: URL) {
        let destination = file.appendingPathExtension("corrupt")
        try? FileManager.default.moveItem(at: file, to: destination)
    }

    // MARK: - State

    private func pendingFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func pendingCount() -> Int {
        pendingFiles().count
    }

    func refreshPendingStatus() async {
        let count = pendingFiles().count
        let retry = failureCount > 0 && count > 0 ? nextAttempt : nil
        if let destinationID {
            await status.setDestinationOutbox(destinationID, pending: count, nextRetry: retry)
        } else {
            await status.setOutbox(pending: count, nextRetry: retry)
        }
    }

    func removeAll() async {
        for file in pendingFiles() {
            try? FileManager.default.removeItem(at: file)
        }
        failureCount = 0
        nextAttempt = .distantPast
        await refreshPendingStatus()
    }
}

/// The original POST: gzipped bare array through an `Uploading`.
struct LegacyUploadTransport: Transport {
    let uploader: Uploading
    let url: URL
    let token: String?

    func deliver(_ batch: Batch) async throws -> UploadResult {
        let body = try Wire.encodeElements(batch.elements)
        return try await uploader.send(Gzip.compress(body), gzipped: true, to: url, token: token)
    }
}
