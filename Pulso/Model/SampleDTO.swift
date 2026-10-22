import Foundation

/// One health sample as it appears on the wire. Optional fields are omitted
/// when absent. See docs/PROTOCOL.md for the authoritative schema.
struct SampleDTO: Codable, Equatable, Sendable {
    var uuid: String
    var type: String
    var start: String
    var end: String
    var value: SampleValue? = nil
    var unit: String? = nil
    var source: String
    var sourceBundleId: String? = nil
    /// The sample's full HealthKit metadata dictionary. "timeZone" appears
    /// only when the sample itself recorded one (HKMetadataKeyTimeZone);
    /// absent means the timestamps' offset is the device timezone at sync
    /// time — an assumption, not a recorded fact.
    var metadata: [String: JSONValue]? = nil

    /// What sort of HealthKit object this is: quantity, category, workout,
    /// route, heartbeatSeries, electrocardiogram, ... Absent on v1 senders.
    var kind: String? = nil
    var sourceVersion: String? = nil
    var sourceProductType: String? = nil
    var sourceOSVersion: String? = nil
    /// HKDevice fields that are set (name, manufacturer, model, ...).
    var device: [String: JSONValue]? = nil
    /// Type-specific structure: route locations, ECG voltages, workout
    /// events and activities, series statistics, prescription lenses, ...
    var details: [String: JSONValue]? = nil

    // Workouts only.
    var workoutActivityType: String? = nil
    var duration: Double? = nil
    var totalEnergyBurned: Double? = nil
    var totalBasalEnergyBurned: Double? = nil
    var totalDistance: Double? = nil
    var averageHeartRate: Double? = nil
    var minimumHeartRate: Double? = nil
    var maximumHeartRate: Double? = nil
}

/// Any JSON value. HealthKit metadata is heterogeneous: strings, numbers,
/// and booleans pass through natively and anything else (HKQuantity, dates)
/// is stringified by the serializer. `details` uses arrays and objects.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "not a JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Category samples carry a string (e.g. "asleepREM"); quantity samples a number.
enum SampleValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else {
            throw DecodingError.typeMismatch(
                SampleValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "value must be a string or a number")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

/// An element of an /ingest batch: either a sample or a deletion tombstone
/// ({"deleted": ["uuid", ...]}) surfaced by an anchored query.
enum BatchElement: Codable, Equatable, Sendable {
    case sample(SampleDTO)
    case tombstone([String])

    private enum TombstoneKeys: String, CodingKey { case deleted }

    var sampleCount: Int {
        if case .sample = self { return 1 }
        return 0
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: TombstoneKeys.self), container.contains(.deleted) {
            self = .tombstone(try container.decode([String].self, forKey: .deleted))
        } else {
            self = .sample(try SampleDTO(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .sample(let dto):
            try dto.encode(to: encoder)
        case .tombstone(let uuids):
            var container = encoder.container(keyedBy: TombstoneKeys.self)
            try container.encode(uuids, forKey: .deleted)
        }
    }
}

/// One durable outbox file: a slice of query results plus the anchor to
/// persist once the server ACKs it. `anchor` is nil on every slice but the
/// last when a single query result is split by size — the anchor may only
/// advance once *all* of the result is delivered.
struct Batch: Codable, Sendable {
    let id: UUID
    let typeKey: String
    let createdAt: Date
    let anchor: Data?
    let elements: [BatchElement]

    var sampleCount: Int { elements.reduce(0) { $0 + $1.sampleCount } }
}
