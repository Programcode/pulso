import CryptoKit
import Foundation
import HealthKit

/// Health data that isn't a stream of samples, so anchored queries can't
/// follow it: characteristics, daily activity rings, and the medication
/// list. Each read returns records with stable ids; SyncEngine sends only
/// the ones whose content changed since the last delivered read.
struct SnapshotSource: Identifiable {
    let key: String
    let displayName: String
    let group: String
    let readTypes: Set<HKObjectType>
    /// Types needing a per-object grant (a user tap) instead of the read set.
    let perObjectType: HKObjectType?
    /// True when a read returns every record that exists, so a record
    /// missing from it was deleted. False for windowed reads.
    let complete: Bool
    /// `delivered` holds the record keys (and fingerprints) already queued;
    /// nil when nothing was, so the read should cover all history.
    let read: @Sendable (_ queries: HealthQueries, _ context: SerializerContext, _ delivered: [String: String]?) async throws -> [SampleDTO]

    var id: String { key }
}

enum Snapshots {
    static let appleHealth = "Apple Health"

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Health data unavailable (phone locked?); keeping the last snapshot" }
    }

    static var all: [SnapshotSource] {
        var sources = [characteristics, activitySummaries]
        if #available(iOS 26.0, *) {
            sources.append(medications)
        }
        return sources
    }

    private static func record(
        uuid: String, type: String, start: Date, end: Date, context: SerializerContext,
        value: SampleValue? = nil, details: [String: JSONValue]
    ) -> SampleDTO {
        var dto = SampleDTO(
            uuid: uuid, type: type,
            start: context.timestamp(start), end: context.timestamp(end),
            value: value, source: appleHealth, sourceBundleId: "com.apple.health"
        )
        dto.kind = type
        dto.details = details
        return dto
    }

    // MARK: - Characteristics

    static let characteristics = SnapshotSource(
        key: "characteristics",
        displayName: "Characteristics (birth date, sex, blood type, skin type, wheelchair, move mode)",
        group: TypeRegistry.Group.characteristics,
        readTypes: Set(HealthKitCatalog.characteristics.compactMap { entry -> HKObjectType? in
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(entry.minimumOS) else { return nil }
            return HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: entry.identifier))
        }),
        perObjectType: nil,
        complete: true
    ) { queries, context, _ in
        let store = queries.store
        var details: [String: JSONValue] = [:]
        if let birth = try? store.dateOfBirthComponents(), let year = birth.year, let month = birth.month, let day = birth.day {
            details["dateOfBirth"] = .string(String(format: "%04d-%02d-%02d", year, month, day))
        }
        if let sex = try? store.biologicalSex() {
            details["biologicalSex"] = .string(Serializers.enumName("HKBiologicalSex", sex.biologicalSex.rawValue))
        }
        if let blood = try? store.bloodType() {
            details["bloodType"] = .string(Serializers.enumName("HKBloodType", blood.bloodType.rawValue))
        }
        if let skin = try? store.fitzpatrickSkinType() {
            details["fitzpatrickSkinType"] = .string(Serializers.enumName("HKFitzpatrickSkinType", skin.skinType.rawValue))
        }
        if let wheelchair = try? store.wheelchairUse() {
            details["wheelchairUse"] = .string(Serializers.enumName("HKWheelchairUse", wheelchair.wheelchairUse.rawValue))
        }
        if let moveMode = try? store.activityMoveMode() {
            details["activityMoveMode"] = .string(Serializers.enumName("HKActivityMoveMode", moveMode.activityMoveMode.rawValue))
        }
        // Every getter throws while the phone is locked; an empty record
        // would replace the last good one.
        guard !details.isEmpty else { throw Snapshots.Unavailable() }
        let now = Date()
        return [record(uuid: "characteristics", type: "characteristics", start: now, end: now, context: context, details: details)]
    }

    // MARK: - Activity summaries

    /// HealthKit (and the first Apple Watch data) starts in 2014.
    private static let historyStart = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2014, month: 1, day: 1).date!
    /// Rings for recent days keep changing (late Watch syncs, goal edits).
    private static let recentDays = 35

    static let activitySummaries = SnapshotSource(
        key: "activitySummary",
        displayName: "Activity Rings (daily summaries)",
        group: TypeRegistry.Group.summaries,
        readTypes: [HKObjectType.activitySummaryType()],
        perObjectType: nil,
        complete: false
    ) { queries, context, delivered in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.defaultTimeZone()
        let today = calendar.startOfDay(for: Date())
        let recent = calendar.date(byAdding: .day, value: -recentDays, to: today)!
        let from: Date
        if let delivered {
            // After a gap longer than the recent window, resume from the
            // last day already sent so no day in between is skipped.
            let lastSent = delivered.keys.compactMap { summaryDay(fromKey: $0, calendar: calendar) }.max()
            from = min(lastSent ?? historyStart, recent)
        } else {
            from = historyStart
        }
        var start = calendar.dateComponents([.era, .year, .month, .day], from: from)
        start.calendar = calendar
        var end = calendar.dateComponents([.era, .year, .month, .day], from: today)
        end.calendar = calendar
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
        let summaries = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(for: queries.store)

        return summaries.compactMap { summary -> SampleDTO? in
            let components = summary.dateComponents(for: calendar)
            guard let day = calendar.date(from: components),
                  let next = calendar.date(byAdding: .day, value: 1, to: day),
                  let year = components.year, let month = components.month, let dayOfMonth = components.day else { return nil }
            let kcal = HKUnit.kilocalorie()
            let minutes = HKUnit.minute()
            let count = HKUnit.count()
            var details: [String: JSONValue] = [
                "date": .string(String(format: "%04d-%02d-%02d", year, month, dayOfMonth)),
                "activityMoveMode": .string(Serializers.enumName("HKActivityMoveMode", summary.activityMoveMode.rawValue)),
            ]
            details["activeEnergyBurnedKcal"] = Serializers.json(summary.activeEnergyBurned, kcal)
            details["activeEnergyBurnedGoalKcal"] = Serializers.json(summary.activeEnergyBurnedGoal, kcal)
            details["appleMoveTimeMin"] = Serializers.json(summary.appleMoveTime, minutes)
            details["appleMoveTimeGoalMin"] = Serializers.json(summary.appleMoveTimeGoal, minutes)
            details["appleExerciseTimeMin"] = Serializers.json(summary.appleExerciseTime, minutes)
            details["exerciseTimeGoalMin"] = Serializers.json(summary.exerciseTimeGoal, minutes)
            details["appleStandHours"] = Serializers.json(summary.appleStandHours, count)
            details["standHoursGoal"] = Serializers.json(summary.standHoursGoal, count)
            if #available(iOS 18.0, *) {
                details["paused"] = .bool(summary.isPaused)
            }
            return record(
                uuid: "activitySummary-\(year)-\(String(format: "%02d-%02d", month, dayOfMonth))",
                type: "activitySummary", start: day, end: next, context: context, details: details
            )
        }
    }

    private static func summaryDay(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 4, parts[0] == "activitySummary",
              let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    // MARK: - Medications

    @available(iOS 26.0, *)
    static var medications: SnapshotSource { SnapshotSource(
        key: "medication",
        displayName: "Medication List",
        group: TypeRegistry.Group.medications,
        readTypes: [],
        perObjectType: HKObjectType.userAnnotatedMedicationType(),
        complete: true
    ) { queries, context, _ in
        let now = Date()
        return try await queries.userAnnotatedMedications().map { annotated in
            let concept = annotated.medication
            let key = MedicationIdentity.key(concept.identifier)
            var details: [String: JSONValue] = [
                "medicationConcept": .string(key),
                "displayText": .string(concept.displayText),
                "generalForm": .string(concept.generalForm.rawValue),
                "isArchived": .bool(annotated.isArchived),
                "hasSchedule": .bool(annotated.hasSchedule),
                "relatedCodings": .array(concept.relatedCodings.sorted { $0.code < $1.code }.map { coding in
                    var out: [String: JSONValue] = ["system": .string(coding.system), "code": .string(coding.code)]
                    if let version = coding.version { out["version"] = .string(version) }
                    return .object(out)
                }),
            ]
            if let nickname = annotated.nickname { details["nickname"] = .string(nickname) }
            return record(
                uuid: "medication-\(key)", type: "medication", start: now, end: now, context: context,
                value: .string(annotated.nickname ?? concept.displayText), details: details
            )
        }
    } }
}

/// What has been queued for one snapshot source. Every change to a record
/// is sent as a new version with a uuid that is never reused (record key,
/// a random epoch for this state, a version counter), and the version it
/// replaces is tombstoned. Receivers that keep the first copy of a uuid and
/// receivers that upsert both end up with only the latest version.
/// SyncEngine journals each batch with the state it leads to, so the
/// counter can't move backwards across a crash.
struct SnapshotState: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// nil once the record was deleted (its last version tombstoned).
        var fingerprint: String?
        var version: Int
    }

    var epoch: String
    var entries: [String: Entry] = [:]

    static func fresh() -> SnapshotState {
        SnapshotState(epoch: String(UUID().uuidString.prefix(8)).lowercased())
    }

    /// Fingerprints of the records that currently exist, by record key.
    var fingerprints: [String: String] {
        entries.compactMapValues(\.fingerprint)
    }

    func uuid(_ key: String, version: Int) -> String {
        "\(key)-\(epoch)-v\(version)"
    }

    /// Takes one read (records keyed by their `uuid`) and returns the new
    /// versions to send and the uuids of the versions they replace or that
    /// were deleted. An empty read never deletes anything: HealthKit
    /// returns nothing, not an error, when access is missing.
    mutating func apply(_ records: [SampleDTO], complete: Bool) -> (send: [SampleDTO], superseded: [String]) {
        var send: [SampleDTO] = []
        var superseded: [String] = []
        for record in records {
            let key = record.uuid
            let fingerprint = Self.fingerprint(record)
            let previous = entries[key]
            guard previous?.fingerprint != fingerprint else { continue }
            if let previous, previous.fingerprint != nil {
                superseded.append(uuid(key, version: previous.version))
            }
            let version = (previous?.version ?? 0) + 1
            entries[key] = Entry(fingerprint: fingerprint, version: version)
            send.append(versioned(record, version: version))
        }
        if complete && !records.isEmpty {
            let present = Set(records.map(\.uuid))
            for (key, entry) in entries where entry.fingerprint != nil && !present.contains(key) {
                superseded.append(uuid(key, version: entry.version))
                entries[key]?.fingerprint = nil
            }
        }
        return (send, superseded.sorted())
    }

    /// The record as sent: versioned uuid, stable key in details.recordKey.
    func versioned(_ record: SampleDTO, version: Int) -> SampleDTO {
        var out = record
        out.uuid = uuid(record.uuid, version: version)
        var details = out.details ?? [:]
        details["recordKey"] = .string(record.uuid)
        out.details = details
        return out
    }

    /// Content identity of a record; timestamps are left out because
    /// characteristics and medications are stamped at read time.
    static func fingerprint(_ record: SampleDTO) -> String {
        let content: [String: JSONValue] = [
            "value": record.value.map { value -> JSONValue in
                switch value {
                case .string(let s): .string(s)
                case .number(let n): .number(n)
                }
            } ?? .null,
            "details": .object(record.details ?? [:]),
        ]
        let data = (try? Wire.bodyEncoder().encode(content)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
