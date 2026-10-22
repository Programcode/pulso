import CryptoKit
import Foundation

/// Delivers one outbox batch to one destination. A thrown error or a
/// non-2xx status means "not delivered": the batch stays queued.
protocol Transport: Sendable {
    func deliver(_ batch: Batch) async throws -> UploadResult
}

/// Who sent a batch; goes in the pulso.v2 envelope.
struct DeviceInfo: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var model: String
    var systemVersion: String
    var appVersion: String
    var bundleId: String

    /// Filled in on the main actor at launch (UIDevice is main-actor only).
    nonisolated(unsafe) static var current = DeviceInfo(
        id: "unknown", name: "iPhone", model: "iPhone", systemVersion: "",
        appVersion: "", bundleId: Bundle.main.bundleIdentifier ?? ""
    )
}

/// Request bodies for each destination format.
enum BatchBody {
    static let schema = "pulso.v2"

    private struct Envelope: Encodable {
        let schema: String
        let batchId: String
        let type: String
        let createdAt: Date
        let sentAt: Date
        let device: DeviceInfo
        let items: [BatchElement]
    }

    static func make(_ batch: Batch, format: Destination.BodyFormat, device: DeviceInfo, slim: Bool = false) throws -> Data {
        let items = slim ? batch.elements.map(slimmed) : batch.elements
        switch format {
        case .array:
            return try Wire.encodeElements(items)
        case .ndjson:
            return try ndjson(items)
        case .envelope:
            let envelope = Envelope(
                schema: schema, batchId: batch.id.uuidString, type: batch.typeKey,
                createdAt: batch.createdAt, sentAt: Date(), device: device, items: items
            )
            return try Wire.fileEncoder().encode(envelope)
        }
    }

    static func ndjson(_ items: [BatchElement]) throws -> Data {
        let encoder = Wire.bodyEncoder()
        var out = Data()
        for item in items {
            out.append(try encoder.encode(item))
            out.append(0x0A)
        }
        return out
    }

    /// The test body every HTTP destination accepts: an empty batch marked
    /// as a test, so receivers can skip storing it.
    static func test(device: DeviceInfo, format: Destination.BodyFormat) throws -> Data {
        switch format {
        case .array:
            return Data("[]".utf8)
        case .ndjson:
            return Data()
        case .envelope:
            struct Test: Encodable {
                let schema: String
                let test = true
                let sentAt: Date
                let device: DeviceInfo
                let items: [BatchElement] = []
            }
            return try Wire.fileEncoder().encode(Test(schema: schema, sentAt: Date(), device: device))
        }
    }

    /// Long arrays (route locations, ECG voltages, beats, linked sample
    /// ids) replaced by their length — for destinations like Home Assistant
    /// that want the event, not the raw series.
    static func slimmed(_ element: BatchElement) -> BatchElement {
        guard case .sample(var dto) = element, var details = dto.details else { return element }
        for (key, value) in details {
            if case .array(let values) = value, values.count > 50 {
                details[key] = nil
                details[key + "Count"] = .number(Double(values.count))
            }
        }
        dto.details = details
        return .sample(dto)
    }
}

// MARK: - HTTP

struct HTTPTransport: Transport {
    let destination: Destination
    let session: URLSession

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false // fail fast; the outbox owns retries
        return URLSession(configuration: configuration)
    }

    func deliver(_ batch: Batch) async throws -> UploadResult {
        let body = try BatchBody.make(
            batch, format: destination.format, device: DeviceInfo.current,
            slim: destination.kind == .homeAssistant
        )
        return try await post(body, extraHeaders: ["X-Pulso-Batch": batch.id.uuidString, "X-Pulso-Type": batch.typeKey])
    }

    func post(_ raw: Data, extraHeaders: [String: String] = [:]) async throws -> UploadResult {
        guard let url = destination.ingestURL else { throw URLError(.badURL) }
        let body = destination.gzip ? Gzip.compress(raw) : raw
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(destination.format == .ndjson ? "application/x-ndjson" : "application/json",
                         forHTTPHeaderField: "Content-Type")
        if destination.gzip {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for header in destination.headers where !header.name.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name.trimmingCharacters(in: .whitespaces))
        }
        if let token = destination.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let secret = destination.hmacSecret, !secret.isEmpty {
            // Signed over the bytes on the wire (after gzip), which is what
            // the receiver can check before decoding anything.
            request.setValue("sha256=" + Self.hmacHex(body, secret: secret), forHTTPHeaderField: "X-Signature")
        }
        let started = Date()
        let (data, response) = try await session.upload(for: request, from: body)
        return UploadResult(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            bodySnippet: String(decoding: data.prefix(300), as: UTF8.self),
            duration: Date().timeIntervalSince(started)
        )
    }

    static func hmacHex(_ body: Data, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - MQTT

/// One message per type per batch on <prefix>/<type> (a JSON array of
/// items), deletions on <prefix>/deleted. Publishing every sample as its
/// own message would cost a broker round trip each.
struct MQTTTransport: Transport {
    let destination: Destination

    var config: MQTTConfig {
        MQTTConfig(
            host: destination.mqttHost.trimmingCharacters(in: .whitespaces),
            port: UInt16(clamping: destination.mqttPort),
            useTLS: destination.mqttTLS,
            username: destination.mqttUsername.isEmpty ? nil : destination.mqttUsername,
            password: destination.mqttPassword,
            // One per destination: a broker drops the older of two
            // connections that share a client id.
            clientID: "pulso-\(DeviceInfo.current.id.prefix(8))-\(destination.id.uuidString.prefix(8))"
        )
    }

    func topic(_ suffix: String) -> String {
        var prefix = destination.mqttTopicPrefix.trimmingCharacters(in: .whitespaces)
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return prefix.isEmpty ? suffix : "\(prefix)/\(suffix)"
    }

    func deliver(_ batch: Batch) async throws -> UploadResult {
        var byType: [String: [BatchElement]] = [:]
        var deleted: [String] = []
        for element in batch.elements {
            switch element {
            case .sample(let dto): byType[dto.type, default: []].append(element)
            case .tombstone(let uuids): deleted += uuids
            }
        }
        var messages: [(topic: String, payload: Data, retain: Bool)] = []
        for (type, items) in byType.sorted(by: { $0.key < $1.key }) {
            messages.append((topic(type), try Wire.encodeElements(items), destination.mqttRetain))
        }
        if !deleted.isEmpty {
            messages.append((topic("deleted"), try Wire.encodeElements([.tombstone(deleted)]), false))
        }
        let started = Date()
        try await MQTTPublisher.publish(messages, config: config)
        return UploadResult(
            status: 200, bodySnippet: "published \(messages.count) message(s)",
            duration: Date().timeIntervalSince(started)
        )
    }

    func test() async throws {
        let payload = try BatchBody.test(device: DeviceInfo.current, format: .envelope)
        try await MQTTPublisher.publish([(topic("test"), payload, false)], config: config)
    }
}

// MARK: - Files

/// Appends NDJSON lines to <folder>/pulso-<yyyy-MM-dd>.ndjson, one file per
/// day of export. The folder is the app's own (visible in Files under On My
/// iPhone › Pulso) or one the user picked, e.g. in iCloud Drive.
struct FileTransport: Transport {
    let destination: Destination

    static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Pulso Export", isDirectory: true)
    }

    func deliver(_ batch: Batch) async throws -> UploadResult {
        let started = Date()
        let lines = try BatchBody.ndjson(batch.elements)
        let name = "pulso-\(Self.dayStamp(Date())).ndjson"
        try withFolder { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.append(lines, to: folder.appendingPathComponent(name))
        }
        return UploadResult(status: 200, bodySnippet: "appended \(batch.elements.count) line(s) to \(name)",
                            duration: Date().timeIntervalSince(started))
    }

    func test() throws {
        try withFolder { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Pulso can write here.\n".utf8).write(to: folder.appendingPathComponent("pulso-test.txt"), options: .atomic)
        }
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        guard let bookmark = destination.folderBookmark else {
            return try body(Self.defaultFolder)
        }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        // Coordinated, so iCloud Drive sees the write as one change.
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    /// File destinations drain concurrently and may share a folder; one
    /// lock keeps two appends from landing at the same offset.
    private static let appendLock = NSLock()

    private static func append(_ data: Data, to file: URL) throws {
        appendLock.lock()
        defer { appendLock.unlock() }
        if !FileManager.default.fileExists(atPath: file.path) {
            try data.write(to: file, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension Destination {
    var transport: Transport? {
        guard isConfigured else { return nil }
        switch kind {
        case .rest, .pulso, .homeAssistant: return HTTPTransport(destination: self, session: Self.session)
        case .mqtt: return MQTTTransport(destination: self)
        case .file: return FileTransport(destination: self)
        }
    }

    private static let session = HTTPTransport.makeSession()
}
