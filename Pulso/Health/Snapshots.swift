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
    /// `firstRead` is true when nothing was delivered yet, so the read
    /// should cover all history rather than a recent window.
    let read: @Sendable (_ queries: HealthQueries, _ context: SerializerContext, _ firstRead: Bool) async throws -> [SampleDTO]

    var id: String { key }
}

enum Snapshots {
    static let appleHealth = "Apple Health"

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
        perObjectType: nil
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
        perObjectType: nil
    ) { queries, context, firstRead in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.defaultTimeZone()
        let today = calendar.startOfDay(for: Date())
        let from = firstRead ? historyStart : calendar.date(byAdding: .day, value: -recentDays, to: today)!
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

    // MARK: - Medications

    @available(iOS 26.0, *)
    static var medications: SnapshotSource { SnapshotSource(
        key: "medication",
        displayName: "Medication List",
        group: TypeRegistry.Group.medications,
        readTypes: [],
        perObjectType: HKObjectType.userAnnotatedMedicationType()
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
