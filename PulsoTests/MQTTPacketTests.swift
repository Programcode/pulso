import XCTest
@testable import Pulso

final class MQTTPacketTests: XCTestCase {
    private func config(username: String? = nil, password: String? = nil) -> MQTTConfig {
        MQTTConfig(
            host: "broker.example", port: 1883, useTLS: false,
            username: username, password: password, clientID: "pulso", keepAlive: 0x1234
        )
    }

    func testRemainingLengthBoundaries() {
        let cases: [(Int, [UInt8])] = [
            (0, [0x00]),
            (127, [0x7f]),
            (128, [0x80, 0x01]),
            (16_383, [0xff, 0x7f]),
            (16_384, [0x80, 0x80, 0x01]),
            (2_097_151, [0xff, 0xff, 0x7f]),
            (2_097_152, [0x80, 0x80, 0x80, 0x01]),
            (268_435_455, [0xff, 0xff, 0xff, 0x7f]),
        ]
        for (length, expected) in cases {
            XCTAssertEqual(MQTTPacket.encodeRemainingLength(length), expected, "length \(length)")
        }
    }

    func testConnectWithoutCredentials() {
        XCTAssertEqual(MQTTPacket.connect(config()), Data([
            0x10, 0x11,
            0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04,
            0x02, 0x12, 0x34,
            0x00, 0x05, 0x70, 0x75, 0x6c, 0x73, 0x6f,
        ]))
    }

    func testRemainingLengthValidationRejectsOverflowWithoutAllocatingPayload() throws {
        try MQTTPacket.validateLength(268_435_455)
        for length in [-1, 268_435_456, Int.max] {
            XCTAssertThrowsError(try MQTTPacket.validateLength(length)) { error in
                guard let mqttError = error as? MQTTError, case .protocolViolation = mqttError else {
                    return XCTFail("Expected protocolViolation, got \(error)")
                }
            }
        }
    }

    func testConnectWithCredentials() {
        XCTAssertEqual(MQTTPacket.connect(config(username: "u", password: "pw")), Data([
            0x10, 0x18,
            0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04,
            0xc2, 0x12, 0x34,
            0x00, 0x05, 0x70, 0x75, 0x6c, 0x73, 0x6f,
            0x00, 0x01, 0x75,
            0x00, 0x02, 0x70, 0x77,
        ]))
    }

    func testConnectOmitsEmptyCredentialsAndCanDisableCleanSession() throws {
        XCTAssertEqual(MQTTPacket.connect(config(username: "", password: "")), MQTTPacket.connect(config()))
        let usernameOnly = try XCTUnwrap(MQTTPacket.parseFrame(
            MQTTPacket.connect(config(username: "u", password: ""), cleanSession: false)
        ))
        XCTAssertEqual(usernameOnly.body[7], 0x80)
        XCTAssertEqual(Array(usernameOnly.body.suffix(3)), [0, 1, 0x75])
    }

    func testConnectValidationRejectsPasswordWithoutUsername() throws {
        let usernames: [String?] = [nil, ""]
        for username in usernames {
            XCTAssertThrowsError(try MQTTPacket.validateCredentials(config(username: username, password: "pw"))) { error in
                guard let mqttError = error as? MQTTError, case .protocolViolation = mqttError else {
                    return XCTFail("Expected protocolViolation, got \(error)")
                }
            }
        }
        try MQTTPacket.validateCredentials(config())
        try MQTTPacket.validateCredentials(config(username: "", password: ""))
        try MQTTPacket.validateCredentials(config(username: "u", password: "pw"))
        try MQTTPacket.validateCredentials(config(username: "u"))
    }

    func testPublishQoSOneHeaderAndPacketID() throws {
        for retain in [false, true] {
            let packet = MQTTPacket.publish(topic: "a/b", payload: Data([0, 0xff]), packetID: 0x1234, retain: retain)
            XCTAssertEqual(packet, Data([
                retain ? 0x33 : 0x32, 0x09,
                0x00, 0x03, 0x61, 0x2f, 0x62, 0x12, 0x34, 0x00, 0xff,
            ]))
            let frame = try XCTUnwrap(MQTTPacket.parseFrame(packet))
            XCTAssertEqual(frame.type, 3)
            XCTAssertEqual(frame.flags, retain ? 3 : 2)
        }
    }

    func testPublishUsesUTF8ByteLength() throws {
        let packet = MQTTPacket.publish(topic: "é/心", payload: Data(), packetID: 1, retain: false)
        let frame = try XCTUnwrap(MQTTPacket.parseFrame(packet))
        XCTAssertEqual(frame.body, Data([0, 6, 0xc3, 0xa9, 0x2f, 0xe5, 0xbf, 0x83, 0, 1]))
    }

    func testConnectUsesUTF8ByteLength() throws {
        var settings = config()
        settings.clientID = "心"
        let frame = try XCTUnwrap(MQTTPacket.parseFrame(MQTTPacket.connect(settings)))
        XCTAssertEqual(Array(frame.body.suffix(5)), [0, 3, 0xe5, 0xbf, 0x83])
    }

    func testParsePartialAndExactFrames() throws {
        let connack = Data([0x20, 0x02, 0x00, 0x00])
        let puback = Data([0x40, 0x02, 0x12, 0x34])
        for packet in [connack, puback] {
            for count in 0 ..< packet.count {
                XCTAssertNil(MQTTPacket.parseFrame(Data(packet.prefix(count))))
            }
            let frame = try XCTUnwrap(MQTTPacket.parseFrame(packet))
            XCTAssertEqual(frame.type, packet[0] >> 4)
            XCTAssertEqual(frame.flags, 0)
            XCTAssertEqual(frame.body, Data(packet.suffix(2)))
            XCTAssertEqual(frame.consumed, 4)
        }
    }

    func testParseConcatenatedFramesAndNonzeroBufferIndices() throws {
        var buffer = Data([0x20, 0x02, 0x00, 0x00, 0x40, 0x02, 0xab, 0xcd])
        let first = try XCTUnwrap(MQTTPacket.parseFrame(buffer))
        XCTAssertEqual(first.type, 2)
        XCTAssertEqual(first.body, Data([0, 0]))
        XCTAssertEqual(first.consumed, 4)
        buffer.removeFirst(first.consumed)
        let second = try XCTUnwrap(MQTTPacket.parseFrame(buffer))
        XCTAssertEqual(second.type, 4)
        XCTAssertEqual(second.body, Data([0xab, 0xcd]))
        XCTAssertEqual(second.consumed, 4)
        buffer.removeFirst(second.consumed)
        XCTAssertNil(MQTTPacket.parseFrame(buffer))
    }

    func testParsePartialMultibyteLengthAndLargePayload() throws {
        let payload = Data(repeating: 0xa5, count: 2_097_152)
        let packet = MQTTPacket.publish(topic: "x", payload: payload, packetID: .max, retain: false)
        for count in 1 ... 5 {
            XCTAssertNil(MQTTPacket.parseFrame(Data(packet.prefix(count))))
        }
        XCTAssertNil(MQTTPacket.parseFrame(Data(packet.dropLast())))
        let frame = try XCTUnwrap(MQTTPacket.parseFrame(packet))
        XCTAssertEqual(frame.consumed, packet.count)
        XCTAssertEqual(Array(frame.body.prefix(5)), [0, 1, 0x78, 0xff, 0xff])
        XCTAssertEqual(Data(frame.body.dropFirst(5)), payload)
    }

    func testParseRejectsMalformedRemainingLengths() {
        XCTAssertNil(MQTTPacket.parseFrame(Data([0x20, 0xff, 0xff, 0xff, 0xff])))
        XCTAssertNil(MQTTPacket.parseFrame(Data([0x20, 0x80, 0x00])))
    }

    func testControlPacketsHaveEmptyBodies() throws {
        XCTAssertEqual(MQTTPacket.disconnect(), Data([0xe0, 0]))
        XCTAssertEqual(MQTTPacket.pingreq(), Data([0xc0, 0]))
        let frame = try XCTUnwrap(MQTTPacket.parseFrame(MQTTPacket.pingreq()))
        XCTAssertEqual(frame.type, 12)
        XCTAssertTrue(frame.body.isEmpty)
        XCTAssertEqual(frame.consumed, 2)
    }
}
