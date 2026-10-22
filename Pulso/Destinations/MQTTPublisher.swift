import Foundation
import Network

struct MQTTConfig: Sendable, Equatable {
    var host: String
    var port: UInt16
    var useTLS: Bool
    var username: String?
    var password: String?
    var clientID: String
    var keepAlive: UInt16 = 60
}

enum MQTTError: LocalizedError, Equatable {
    case connectionRefused(returnCode: UInt8)
    case timeout
    case closed
    case protocolViolation(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .connectionRefused(let returnCode):
            return "MQTT connection refused (code \(returnCode))."
        case .timeout:
            return "MQTT connection timed out."
        case .closed:
            return "MQTT connection closed."
        case .protocolViolation(let reason):
            return "MQTT protocol violation: \(reason)"
        case .network(let reason):
            return "MQTT network error: \(reason)"
        }
    }
}

enum MQTTPublisher {
    /// Connects, publishes every message with QoS 1 and waits for each PUBACK, then sends DISCONNECT and closes.
    /// A failed batch may have delivered a prefix; callers must tolerate duplicate deliveries on retry.
    static func publish(
        _ messages: [(topic: String, payload: Data, retain: Bool)],
        config: MQTTConfig,
        timeout: TimeInterval = 20
    ) async throws {
        guard timeout.isFinite, timeout > 0 else { throw MQTTError.timeout }
        guard !config.host.isEmpty, config.port != 0 else {
            throw MQTTError.protocolViolation("Host and port must be nonempty and nonzero.")
        }
        try MQTTPacket.validateCredentials(config)
        try MQTTPacket.validateString(config.clientID)
        var connectLength = 10 + 2 + config.clientID.utf8.count
        for credential in [config.username, config.password] {
            if let credential, !credential.isEmpty {
                try MQTTPacket.validateString(credential)
                connectLength += 2 + credential.utf8.count
            }
        }
        try MQTTPacket.validateLength(connectLength)
        for message in messages {
            try MQTTPacket.validateString(message.topic)
            guard !message.topic.isEmpty, !message.topic.contains("#"), !message.topic.contains("+") else {
                throw MQTTError.protocolViolation("PUBLISH requires a nonempty topic without wildcards.")
            }
            try MQTTPacket.validateLength(message.payload.count)
            try MQTTPacket.validateLength(2 + message.topic.utf8.count + 2 + message.payload.count)
        }
        try Task.checkCancellation()

        let session = MQTTSession(config: config)
        defer { session.cancel() }
        try await withTaskCancellationHandler {
            try await session.perform(.connect, timeout: timeout)
            try await session.perform(.connack, sending: MQTTPacket.connect(config), timeout: timeout)
            var packetID: UInt16 = 1
            for message in messages {
                try Task.checkCancellation()
                let packet = MQTTPacket.publish(
                    topic: message.topic, payload: message.payload, packetID: packetID, retain: message.retain
                )
                try await session.perform(.puback(packetID), sending: packet, timeout: timeout)
                packetID = packetID == .max ? 1 : packetID + 1
            }
            try await session.perform(.disconnect, sending: MQTTPacket.disconnect(), timeout: timeout)
        } onCancel: {
            session.cancel()
        }
    }
}

/// Encoding assumes validated input. The publisher checks the whole batch before
/// connecting so invalid lengths fail without publishing a prefix of that batch.
enum MQTTPacket {
    private static let maximumLength = 268_435_455

    static func encodeRemainingLength(_ length: Int) -> [UInt8] {
        precondition((0 ... maximumLength).contains(length), "Invalid MQTT remaining length")
        var remaining = length
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining > 0
        return bytes
    }

    static func connect(_ config: MQTTConfig, cleanSession: Bool = true) -> Data {
        let username = config.username.flatMap { $0.isEmpty ? nil : $0 }
        let password = config.password.flatMap { $0.isEmpty ? nil : $0 }
        var flags: UInt8 = cleanSession ? 0x02 : 0
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        var body = Data([0, 4, 0x4d, 0x51, 0x54, 0x54, 4, flags])
        appendUInt16(config.keepAlive, to: &body)
        appendString(config.clientID, to: &body)
        if let username { appendString(username, to: &body) }
        if let password { appendString(password, to: &body) }
        return frame(header: 0x10, body: body)
    }

    static func publish(topic: String, payload: Data, packetID: UInt16, retain: Bool) -> Data {
        precondition(packetID != 0, "MQTT packet IDs must be nonzero")
        var body = Data()
        appendString(topic, to: &body)
        appendUInt16(packetID, to: &body)
        body.append(payload)
        return frame(header: retain ? 0x33 : 0x32, body: body)
    }

    static func disconnect() -> Data { Data([0xe0, 0]) }
    static func pingreq() -> Data { Data([0xc0, 0]) }

    static func parseFrame(_ buffer: Data) -> (type: UInt8, flags: UInt8, body: Data, consumed: Int)? {
        try? checkedFrame(buffer)
    }

    /// The receive path distinguishes malformed lengths from frames that need more bytes.
    fileprivate static func checkedFrame(_ buffer: Data) throws -> (type: UInt8, flags: UInt8, body: Data, consumed: Int)? {
        guard let header = buffer.first else { return nil }
        var index = buffer.index(after: buffer.startIndex)
        var length = 0
        var multiplier = 1
        for digit in 0 ..< 4 {
            guard index < buffer.endIndex else { return nil }
            let byte = buffer[index]
            buffer.formIndex(after: &index)
            length += Int(byte & 0x7f) * multiplier
            if byte & 0x80 == 0 {
                guard digit == 0 || byte != 0 else {
                    throw MQTTError.protocolViolation("Noncanonical remaining length.")
                }
                guard buffer.distance(from: index, to: buffer.endIndex) >= length else { return nil }
                let end = buffer.index(index, offsetBy: length)
                return (header >> 4, header & 0x0f, Data(buffer[index ..< end]), 2 + digit + length)
            }
            multiplier *= 128
        }
        throw MQTTError.protocolViolation("Remaining length exceeds four bytes.")
    }

    static func validateLength(_ length: Int) throws {
        guard (0 ... maximumLength).contains(length) else {
            throw MQTTError.protocolViolation("Packet exceeds the MQTT remaining-length limit.")
        }
    }

    static func validateCredentials(_ config: MQTTConfig) throws {
        if let password = config.password, !password.isEmpty {
            guard let username = config.username, !username.isEmpty else {
                throw MQTTError.protocolViolation("A password requires a nonempty username.")
            }
        }
    }

    fileprivate static func validateString(_ string: String) throws {
        guard string.utf8.count <= Int(UInt16.max), !string.utf8.contains(0) else {
            throw MQTTError.protocolViolation("String exceeds 65535 UTF-8 bytes or contains a null character.")
        }
    }

    private static func frame(header: UInt8, body: Data) -> Data {
        var packet = Data([header])
        packet.append(contentsOf: encodeRemainingLength(body.count))
        packet.append(body)
        return packet
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
    }

    private static func appendString(_ string: String, to data: inout Data) {
        let bytes = Data(string.utf8)
        precondition(bytes.count <= Int(UInt16.max), "MQTT string exceeds two-byte length")
        appendUInt16(UInt16(bytes.count), to: &data)
        data.append(bytes)
    }
}

/// All mutable state, including continuation ownership, lives on queue.
/// Serializing timeout, cancellation and Network callbacks makes each step complete once.
private final class MQTTSession: @unchecked Sendable {
    enum Step: Equatable, Sendable {
        case connect
        case connack
        case puback(UInt16)
        case disconnect
    }

    private let queue = DispatchQueue(label: "Pulso.MQTTPublisher")
    private let connection: NWConnection
    private var buffer = Data()
    private var terminalError: MQTTError?
    private var step: Step?
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var sent = false
    private var acknowledged = false

    init(config: MQTTConfig) {
        connection = NWConnection(
            host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: config.port)!,
            using: config.useTLS ? .tls : .tcp
        )
    }

    func perform(_ next: Step, sending packet: Data? = nil, timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let terminalError {
                    pending.resume(throwing: terminalError)
                    return
                }
                precondition(continuation == nil)
                continuation = pending
                step = next
                generation &+= 1
                let token = generation
                sent = packet == nil
                acknowledged = false
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == token, self.continuation != nil else { return }
                    self.fail(.timeout)
                }
                deadline = timer
                queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                if next == .connect {
                    start()
                } else if let packet {
                    connection.send(content: packet, completion: .contentProcessed { [self] error in
                        if let error { fail(.network(error.localizedDescription)); return }
                        guard generation == token, continuation != nil else { return }
                        sent = true
                        if next == .disconnect || acknowledged { succeed() }
                    })
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in fail(.closed) }
    }

    private func start() {
        connection.stateUpdateHandler = { [self] state in
            guard terminalError == nil else { return }
            switch state {
            case .ready:
                guard step == .connect else { return }
                succeed()
                receive()
            case .failed(let error), .waiting(let error):
                fail(.network(error.localizedDescription))
            case .cancelled:
                fail(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            guard terminalError == nil else { return }
            if let data { buffer.append(data) }
            do {
                while let frame = try MQTTPacket.checkedFrame(buffer) {
                    buffer.removeFirst(frame.consumed)
                    try accept(type: frame.type, flags: frame.flags, body: frame.body)
                }
            } catch let error as MQTTError {
                fail(error)
                return
            } catch {
                fail(.protocolViolation(error.localizedDescription))
                return
            }
            if let error { fail(.network(error.localizedDescription)); return }
            if complete { fail(.closed); return }
            receive()
        }
    }

    private func accept(type: UInt8, flags: UInt8, body: Data) throws {
        guard flags == 0 else { throw MQTTError.protocolViolation("Unexpected fixed-header flags.") }
        if type == 13 {
            guard body.isEmpty else { throw MQTTError.protocolViolation("Malformed PINGRESP.") }
            return
        }
        guard !acknowledged else { throw MQTTError.protocolViolation("Duplicate acknowledgement.") }
        switch step {
        case .connack:
            guard type == 2, body.count == 2, body[0] == 0 else {
                throw MQTTError.protocolViolation("Expected a clean-session CONNACK.")
            }
            guard body[1] == 0 else { throw MQTTError.connectionRefused(returnCode: body[1]) }
        case .puback(let packetID):
            guard type == 4, body.count == 2,
                  (UInt16(body[0]) << 8 | UInt16(body[1])) == packetID else {
                throw MQTTError.protocolViolation("Expected PUBACK for the current packet ID.")
            }
        default:
            throw MQTTError.protocolViolation("Unexpected packet type \(type).")
        }
        acknowledged = true
        if sent { succeed() }
    }

    private func succeed() {
        let pending = continuation
        continuation = nil
        step = nil
        deadline?.cancel()
        deadline = nil
        pending?.resume()
    }

    private func fail(_ error: MQTTError) {
        guard terminalError == nil else { return }
        terminalError = error
        let pending = continuation
        continuation = nil
        step = nil
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending?.resume(throwing: error)
    }
}
