import HealthKit
import XCTest
@testable import Pulso

final class HealthKitCatalogTests: XCTestCase {
    private let context = SerializerContext(
        defaultTimeZone: { TimeZone(identifier: "Asia/Dubai")! },
        formatter: TimestampFormatter()
    )

    /// Every identifier the generated catalog lists for this OS must resolve,
    /// and every quantity must get a unit HKUnit parses and the type accepts.
    func testEveryCatalogTypeResolvesWithAUsableUnit() {
        var problems: [String] = []
        var unprovided: [String] = []
        let info = ProcessInfo.processInfo
        for entry in HealthKitCatalog.quantities where info.isOperatingSystemAtLeast(entry.minimumOS) {
            guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: entry.identifier)) else {
                unprovided.append(entry.identifier)
                continue
            }
            if TypeRegistry.presentation(for: type) == nil {
                problems.append("no usable unit for \(entry.identifier) (\(entry.unit))")
            }
        }
        for entry in HealthKitCatalog.categories where info.isOperatingSystemAtLeast(entry.minimumOS) {
            if HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: entry.identifier)) == nil {
                unprovided.append(entry.identifier)
            }
            if let valueEnum = entry.valueEnum, HealthKitCatalog.enumNames[valueEnum] == nil {
                problems.append("no value names for \(entry.identifier) (\(valueEnum))")
            }
        }
        for entry in HealthKitCatalog.characteristics where info.isOperatingSystemAtLeast(entry.minimumOS) {
            if HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: entry.identifier)) == nil {
                problems.append("unresolved \(entry.identifier)")
            }
        }
        XCTAssertEqual(problems, [])
        // Some identifiers stay in the headers after HealthKit stops
        // providing them; those must be reported as skipped, not crash.
        print("PULSO-UNPROVIDED \(unprovided)")
        XCTAssertLessThan(unprovided.count, 5)
        let skipped = Set(TypeRegistry.skipped.map(\.identifier))
        for identifier in unprovided {
            XCTAssertTrue(skipped.contains(identifier), identifier)
        }
        XCTAssertGreaterThan(TypeRegistry.all.count, 180)
    }

    /// The probe must leave a read set HealthKit accepts as a whole —
    /// requesting it is what the Grant button does.
    func testReadSetProbeLeavesAnAcceptedSet() throws {
        let store = HKHealthStore()
        let readSet = HealthAuthorization.readSet(TypeRegistry.readTypes, store: store)
        print("PULSO-READSET accepted=\(readSet.accepted.count) refused=\(readSet.rejected.keys.sorted())")
        for (identifier, reason) in readSet.rejected {
            print("PULSO-REFUSED \(identifier): \(reason)")
        }
        XCTAssertGreaterThan(readSet.accepted.count, 150)
        // Accepted only together with HRV; must survive the probe.
        XCTAssertTrue(readSet.accepted.contains(HKSeriesType.heartbeat()))
        XCTAssertNoThrow(try ObjC.catching {
            store.getRequestStatusForAuthorization(toShare: [], read: readSet.accepted) { _, _ in }
        })
    }

    func testCategoryValuesSerializeByEnumName() throws {
        let start = TestSupport.date(2026, 7, 6, 10, 0, zone: "Asia/Dubai")
        let headache = HKCategorySample(
            type: HKCategoryType(.headache), value: HKCategoryValueSeverity.moderate.rawValue,
            start: start, end: start.addingTimeInterval(3600)
        )
        let dto = try XCTUnwrap(TypeRegistry.type(for: "headache")?.serialize(headache, context))
        XCTAssertEqual(dto.value, .string("moderate"))
        XCTAssertEqual(dto.kind, "category")
        XCTAssertEqual(Serializers.enumName("HKCategoryValueSeverity", 999), "value_999")
    }

    func testStateOfMindAndAssessmentsReadTheirRefinedArrays() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("needs iOS 18") }
        let now = Date()
        let state = HKStateOfMind(
            date: now, kind: .momentaryEmotion, valence: 0.5,
            labels: [.happy, .calm], associations: [.fitness]
        )
        let mood = try XCTUnwrap(Serializers.stateOfMind(state, context: context))
        XCTAssertEqual(mood.details?["labels"], ["happy", "calm"])
        XCTAssertEqual(mood.details?["associations"], ["fitness"])
        XCTAssertEqual(mood.details?["kind"], "momentaryEmotion")

        let gad7 = HKGAD7Assessment(date: now, answers: Array(repeating: .severalDays, count: 7))
        let serialize = try XCTUnwrap(TypeRegistry.type(for: "gad7")).serialize
        let dto = try XCTUnwrap(serialize(gad7, context))
        XCTAssertEqual(dto.value, .number(7))
        XCTAssertEqual(dto.details?["risk"], "mild")
        XCTAssertEqual(dto.details?["answers"], .array(Array(repeating: "severalDays", count: 7)))
    }

    /// Snapshot records are stamped at read time; only content may decide
    /// whether a record is re-sent.
    func testSnapshotFingerprintIgnoresTimestamps() {
        var a = SampleDTO(uuid: "characteristics", type: "characteristics", start: "2026-01-01T00:00:00Z",
                          end: "2026-01-01T00:00:00Z", source: "Apple Health")
        a.details = ["bloodType": "oPositive"]
        var b = a
        b.start = "2026-02-02T00:00:00Z"
        b.end = b.start
        XCTAssertEqual(SyncEngine.fingerprint(a), SyncEngine.fingerprint(b))
        b.details = ["bloodType": "aNegative"]
        XCTAssertNotEqual(SyncEngine.fingerprint(a), SyncEngine.fingerprint(b))
    }
}
