import XCTest
@testable import Pulso

/// Scriptable transport: fails while `failing` is set, records batches.
final class MockTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: [Batch] = []
    var failing = false

    var batches: [Batch] {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func deliver(_ batch: Batch) async throws -> UploadResult {
        lock.lock()
        defer { lock.unlock() }
        if failing { throw URLError(.cannotConnectToHost) }
        delivered.append(batch)
        return UploadResult(status: 200, bodySnippet: "ok", duration: 0)
    }
}

@MainActor
final class DestinationTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("destination-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func sample(_ id: String) -> BatchElement {
        .sample(SampleDTO(uuid: id, type: "heartRate", start: "2026-07-06T01:12:00+01:00",
                          end: "2026-07-06T01:12:00+01:00", value: .number(60), unit: "count/min", source: "test"))
    }

    private func pendingFiles(_ id: UUID) -> [String] {
        let folder = base.appendingPathComponent(id.uuidString)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    /// Each destination has its own queue: one that is down keeps its
    /// batch while the other delivers.
    func testHubFansOutAndAFailingDestinationOnlyDelaysItself() async throws {
        var up = Destination(name: "up", kind: .file)
        up.enabled = true
        var down = Destination(name: "down", kind: .file)
        down.enabled = true
        let upTransport = MockTransport()
        let downTransport = MockTransport()
        downTransport.failing = true
        let transports: [UUID: MockTransport] = [up.id: upTransport, down.id: downTransport]
        let destinations = [up, down]
        let hub = OutboxHub(
            root: base, log: LogStore(directory: base), status: AppStatus(),
            destinations: { destinations },
            transport: { destination in transports[destination.id] }
        )

        try await hub.enqueue(typeKey: "heartRate", elements: [sample("a"), sample("b")])
        await hub.drain(force: true)

        XCTAssertEqual(upTransport.batches.count, 1)
        XCTAssertEqual(upTransport.batches.first?.elements.count, 2)
        XCTAssertEqual(pendingFiles(up.id), [])
        XCTAssertEqual(pendingFiles(down.id).count, 1, "undelivered batch must stay on disk")

        downTransport.failing = false
        await hub.drain(force: true)
        XCTAssertEqual(downTransport.batches.count, 1)
        XCTAssertEqual(pendingFiles(down.id), [])
    }

    func testHubRefusesToEnqueueWithoutADestination() async {
        let hub = OutboxHub(root: base, log: LogStore(directory: base), status: AppStatus(), destinations: { [] })
        do {
            try await hub.enqueue(typeKey: "heartRate", elements: [sample("a")])
            XCTFail("enqueue must throw so the caller keeps its anchor")
        } catch {}
    }

    /// RFC 4231 test case 2.
    func testHMACMatchesTheKnownVector() {
        let mac = HTTPTransport.hmacHex(Data("what do ya want for nothing?".utf8), secret: "Jefe")
        XCTAssertEqual(mac, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    func testEnvelopeCarriesSchemaDeviceAndItems() throws {
        let batch = Batch(id: UUID(), typeKey: "heartRate", createdAt: Date(), anchor: nil,
                          elements: [sample("a"), .tombstone(["gone"])])
        let device = DeviceInfo(id: "D", name: "Phone", model: "iPhone", systemVersion: "26.0",
                                appVersion: "1.0 (1)", bundleId: "x")
        let body = try BatchBody.make(batch, format: .envelope, device: device)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, "pulso.v2")
        XCTAssertEqual(json["type"] as? String, "heartRate")
        XCTAssertEqual((json["device"] as? [String: Any])?["id"] as? String, "D")
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["uuid"] as? String, "a")
        XCTAssertEqual(items[1]["deleted"] as? [String], ["gone"])

        let array = try BatchBody.make(batch, format: .array, device: device)
        XCTAssertEqual(try JSONDecoder().decode([BatchElement].self, from: array), batch.elements)
    }

    func testSlimmingReplacesLongSeriesWithTheirLength() {
        var dto = SampleDTO(uuid: "r", type: "workoutRoute", start: "s", end: "e", source: "x")
        dto.details = ["locations": .array(Array(repeating: .number(1), count: 500)), "workoutUUID": "w"]
        guard case .sample(let slim) = BatchBody.slimmed(.sample(dto)) else { return XCTFail() }
        XCTAssertNil(slim.details?["locations"])
        XCTAssertEqual(slim.details?["locationsCount"], .number(500))
        XCTAssertEqual(slim.details?["workoutUUID"], "w")
    }

    func testPulsoKindPostsToIngestUnderTheBaseURL() {
        var destination = Destination(name: "p", kind: .pulso)
        destination.url = "100.64.0.7:8787/"
        XCTAssertEqual(destination.ingestURL?.absoluteString, "http://100.64.0.7:8787/ingest")
        XCTAssertEqual(destination.format, .array)
        XCTAssertEqual(destination.latestURL?.absoluteString, "http://100.64.0.7:8787/latest")
        var rest = Destination(name: "r", kind: .rest)
        rest.url = "health.example.net:8797/ingest/pulso"
        XCTAssertEqual(rest.ingestURL?.absoluteString, "https://health.example.net:8797/ingest/pulso")
        XCTAssertNil(rest.latestURL, "catch-up is opt-in for REST")
    }

    /// The anchor is shared, so the catch-up point must suit every
    /// destination: earliest timestamp per type, and only types all have.
    func testCatchUpUsesTheEarliestAnswerAndOnlySharedTypes() {
        let merged = CatchUp.earliest([
            ["heartRate": "2026-07-15T08:59:12+01:00", "stepCount": "2026-07-15T09:00:00+01:00"],
            ["heartRate": "2026-07-10T08:00:00+02:00"],
        ])
        XCTAssertEqual(merged, ["heartRate": "2026-07-10T08:00:00+02:00"])
        XCTAssertEqual(CatchUp.earliest([]), [:])
    }

    func testResendRangeMatchesOverlappingRecordsOnly() {
        let day = SampleDTO(uuid: "d", type: "activitySummary", start: "2026-10-21T00:00:00+02:00",
                            end: "2026-10-22T00:00:00+02:00", source: "x")
        let iso = ISO8601DateFormatter()
        XCTAssertTrue(SyncEngine.overlaps(day, start: iso.date(from: "2026-10-21T12:00:00Z"), end: nil))
        XCTAssertFalse(SyncEngine.overlaps(day, start: iso.date(from: "2026-10-23T00:00:00Z"), end: nil))
        XCTAssertFalse(SyncEngine.overlaps(day, start: nil, end: iso.date(from: "2026-10-20T00:00:00Z")))
        XCTAssertTrue(SyncEngine.overlaps(day, start: nil, end: nil))
    }
}
