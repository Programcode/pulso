import Foundation
import HealthKit

/// One syncable HealthKit sample type: its wire key, how eagerly HealthKit
/// may wake us for it, and how its samples serialize.
struct SyncedType: Identifiable {
    enum Access {
        /// Requested in the read set with requestAuthorization.
        case read
        /// Needs requestPerObjectReadAuthorization from a user tap.
        case perObject
        /// Not authorizable itself; readable when its member types are
        /// (blood pressure and food correlations).
        case viaComponents
    }

    let key: String // wire "type" value and persistence key
    let displayName: String
    let group: String // UI section
    let sampleType: HKSampleType
    let frequency: HKUpdateFrequency
    var access: Access = .read
    /// Samples per anchored query page. Lower for types whose samples are
    /// large (route locations, ECG voltages) or need follow-up queries.
    var queryLimit: Int = SyncEngine.queryLimit
    let serialize: @Sendable (HKSample, SerializerContext) -> SampleDTO?
    /// Follow-up queries that complete a sample (route locations, ...).
    var enrich: (@Sendable (HealthQueries, SampleDTO, HKSample) async throws -> SampleDTO)? = nil

    var id: String { key }
}

/// How one quantity type's values go on the wire.
struct QuantityPresentation: @unchecked Sendable {
    let key: String
    let unit: HKUnit
    let label: String
    let scale: Double
}

/// Every type the app syncs. Quantity, category and characteristic types
/// come from HealthKitCatalog (generated from the SDK headers); the sample
/// classes that need their own serializer are listed by hand below.
enum TypeRegistry {
    enum Group {
        static let sleep = "Sleep"
        static let fitness = "Fitness"
        static let heart = "Heart"
        static let vitals = "Vital Signs"
        static let respiratory = "Respiratory"
        static let body = "Body Measurements"
        static let mobility = "Mobility"
        static let nutrition = "Nutrition"
        static let hearing = "Hearing Health"
        static let mental = "Mental Wellbeing"
        static let symptoms = "Symptoms"
        static let reproductive = "Reproductive Health"
        static let vision = "Vision"
        static let medications = "Medications"
        static let other = "Other"
        static let characteristics = "Characteristics"
        static let summaries = "Activity Summaries"
    }

    private static let groupOrder = [
        Group.sleep, Group.fitness, Group.summaries, Group.heart, Group.vitals, Group.respiratory,
        Group.body, Group.mobility, Group.nutrition, Group.hearing, Group.mental, Group.symptoms,
        Group.reproductive, Group.vision, Group.medications, Group.other, Group.characteristics,
    ]

    private static func group(forSection section: String) -> String {
        switch section {
        case "Me": Group.characteristics
        case let known where groupOrder.contains(known): known
        default: Group.other
        }
    }

    /// Units Pulso v1.1 put on the wire for its original types, kept so
    /// existing consumers don't break. Every other type uses the SDK's
    /// canonical unit, except heart-rate-like count/s, which reads as
    /// count/min.
    static let legacyUnits: [String: (unit: String, label: String)] = [
        "timeInDaylight": ("min", "min"),
        "appleSleepingWristTemperature": ("degC", "°C"),
        "appleSleepingBreathingDisturbances": ("count", "count"),
        "stepCount": ("count", "count"),
        "activeEnergyBurned": ("kcal", "kcal"),
        "basalEnergyBurned": ("kcal", "kcal"),
        "physicalEffort": ("kcal/(kg*hr)", "kcal/hr·kg"),
        "appleExerciseTime": ("min", "min"),
        "appleStandTime": ("min", "min"),
        "flightsClimbed": ("count", "count"),
        "distanceWalkingRunning": ("m", "m"),
        "distanceCycling": ("m", "m"),
        "distanceSwimming": ("m", "m"),
        "swimmingStrokeCount": ("count", "count"),
        "heartRate": ("count/min", "count/min"),
        "restingHeartRate": ("count/min", "count/min"),
        "heartRateVariabilitySDNN": ("ms", "ms"),
        "vo2Max": ("ml/(kg*min)", "mL/(kg·min)"),
        "heartRateRecoveryOneMinute": ("count/min", "count/min"),
        "walkingHeartRateAverage": ("count/min", "count/min"),
        "oxygenSaturation": ("%", "%"),
        "respiratoryRate": ("count/min", "count/min"),
        "bodyMass": ("kg", "kg"),
        "bodyFatPercentage": ("%", "%"),
        "leanBodyMass": ("kg", "kg"),
        "bodyMassIndex": ("count", "count"),
        "waistCircumference": ("cm", "cm"),
        "height": ("cm", "cm"),
        "runningPower": ("W", "W"),
        "runningSpeed": ("m/s", "m/s"),
        "runningStrideLength": ("m", "m"),
        "runningVerticalOscillation": ("cm", "cm"),
        "runningGroundContactTime": ("ms", "ms"),
        "walkingSpeed": ("m/s", "m/s"),
        "walkingStepLength": ("cm", "cm"),
        "walkingAsymmetryPercentage": ("%", "%"),
        "walkingDoubleSupportPercentage": ("%", "%"),
        "appleWalkingSteadiness": ("%", "%"),
        "sixMinuteWalkTestDistance": ("m", "m"),
        "stairAscentSpeed": ("m/s", "m/s"),
        "stairDescentSpeed": ("m/s", "m/s"),
        "environmentalAudioExposure": ("dBASPL", "dBASPL"),
        "headphoneAudioExposure": ("dBASPL", "dBASPL"),
        "dietaryEnergyConsumed": ("kcal", "kcal"),
        "dietaryProtein": ("g", "g"),
        "dietaryCarbohydrates": ("g", "g"),
        "dietaryFatTotal": ("g", "g"),
        "dietaryFiber": ("g", "g"),
        "dietarySugar": ("g", "g"),
        "dietarySodium": ("mg", "mg"),
        "dietaryWater": ("mL", "mL"),
        "dietaryCaffeine": ("mg", "mg"),
        "numberOfAlcoholicBeverages": ("count", "count"),
    ]

    private static func isAvailable(_ minimum: OperatingSystemVersion) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimum)
    }

    // MARK: - Quantities

    /// HKUnit(from:) raises on a string it can't parse; a type whose unit
    /// doesn't parse or doesn't fit the type is left out (and reported in
    /// `skipped`) rather than crashing the app.
    private static func makePresentation(_ entry: HealthKitCatalog.Quantity, _ type: HKQuantityType) -> QuantityPresentation? {
        var unitString = entry.unit
        var label = entry.unit
        if let legacy = legacyUnits[entry.key] {
            (unitString, label) = legacy
        } else if unitString == "count/s" {
            (unitString, label) = ("count/min", "count/min")
        }
        guard let unit = try? ObjC.catching({ HKUnit(from: unitString) }), type.is(compatibleWith: unit) else {
            return nil
        }
        return QuantityPresentation(key: entry.key, unit: unit, label: label, scale: unitString == "%" ? 100 : 1)
    }

    private static let quantityPresentations: [String: QuantityPresentation] = {
        var out: [String: QuantityPresentation] = [:]
        for entry in HealthKitCatalog.quantities where isAvailable(entry.minimumOS) {
            guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: entry.identifier)),
                  let presentation = makePresentation(entry, type) else { continue }
            out[entry.identifier] = presentation
        }
        return out
    }()

    static func presentation(for type: HKQuantityType) -> QuantityPresentation? {
        quantityPresentations[type.identifier]
    }

    private static let quantityTypes: [SyncedType] = HealthKitCatalog.quantities.compactMap { entry in
        guard isAvailable(entry.minimumOS),
              let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: entry.identifier)),
              let presentation = quantityPresentations[entry.identifier] else { return nil }
        // HealthKit caps most quantity types at hourly background delivery.
        return SyncedType(
            key: entry.key, displayName: entry.name, group: group(forSection: entry.section),
            sampleType: type, frequency: .hourly,
            serialize: Serializers.quantity(
                type: entry.key, unit: presentation.unit, unitLabel: presentation.label, scale: presentation.scale)
        )
    }

    // MARK: - Categories

    private static let categoryTypes: [SyncedType] = HealthKitCatalog.categories.compactMap { entry in
        guard isAvailable(entry.minimumOS),
              let type = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: entry.identifier))
        else { return nil }
        let serialize: @Sendable (HKSample, SerializerContext) -> SampleDTO? = switch entry.key {
        case "sleepAnalysis": Serializers.sleep
        case "sexualActivity": Serializers.sexualActivity
        default: Serializers.category(type: entry.key, valueEnum: entry.valueEnum)
        }
        return SyncedType(
            key: entry.key, displayName: entry.name, group: group(forSection: entry.section),
            sampleType: type, frequency: .immediate, serialize: serialize
        )
    }

    // MARK: - Sample classes with their own shape

    private static let specialTypes: [SyncedType] = {
        var types: [SyncedType] = [
            SyncedType(
                key: "workout", displayName: "Workouts", group: Group.fitness,
                sampleType: .workoutType(), frequency: .immediate, queryLimit: 100,
                serialize: Serializers.workout, enrich: { try await $0.enrichWorkout($1, $2) }
            ),
            SyncedType(
                key: "workoutRoute", displayName: "Workout Routes (GPS)", group: Group.fitness,
                sampleType: HKSeriesType.workoutRoute(), frequency: .immediate, queryLimit: 10,
                serialize: Serializers.plain(type: "workoutRoute", kind: "route"),
                enrich: { try await $0.enrichRoute($1, $2) }
            ),
            SyncedType(
                key: "heartbeatSeries", displayName: "Heartbeat Series (beat-to-beat)", group: Group.heart,
                sampleType: HKSeriesType.heartbeat(), frequency: .immediate, queryLimit: 100,
                serialize: Serializers.plain(type: "heartbeatSeries", kind: "heartbeatSeries"),
                enrich: { try await $0.enrichHeartbeats($1, $2) }
            ),
            SyncedType(
                key: "electrocardiogram", displayName: "ECG (with voltages)", group: Group.heart,
                sampleType: HKObjectType.electrocardiogramType(), frequency: .immediate, queryLimit: 5,
                serialize: Serializers.electrocardiogram, enrich: { try await $0.enrichElectrocardiogram($1, $2) }
            ),
            SyncedType(
                key: "audiogram", displayName: "Audiograms", group: Group.hearing,
                sampleType: HKObjectType.audiogramSampleType(), frequency: .immediate, serialize: Serializers.audiogram
            ),
            SyncedType(
                key: "visionPrescription", displayName: "Vision Prescriptions", group: Group.vision,
                sampleType: HKObjectType.visionPrescriptionType(), frequency: .immediate, access: .perObject,
                serialize: Serializers.visionPrescription
            ),
        ]
        if #available(iOS 18.0, *) {
            types.append(SyncedType(
                key: "stateOfMind", displayName: "State of Mind", group: Group.mental,
                sampleType: HKObjectType.stateOfMindType(), frequency: .immediate, serialize: Serializers.stateOfMind
            ))
            for entry in HealthKitCatalog.otherIdentifiers where entry.kind == "HKScoredAssessmentTypeIdentifier" {
                guard isAvailable(entry.minimumOS),
                      let type = HKObjectType.scoredAssessmentType(
                          forIdentifier: HKScoredAssessmentTypeIdentifier(rawValue: entry.identifier)) else { continue }
                let stem = String(entry.identifier.dropFirst("HKScoredAssessmentTypeIdentifier".count))
                types.append(SyncedType(
                    key: entry.key, displayName: "\(entry.name) Assessment", group: Group.mental,
                    sampleType: type, frequency: .immediate,
                    serialize: Serializers.scoredAssessment(type: entry.key, enumPrefix: "HK\(stem)Assessment")
                ))
            }
        }
        if #available(iOS 26.0, *) {
            types.append(SyncedType(
                key: "medicationDoseEvent", displayName: "Medication Doses", group: Group.medications,
                sampleType: HKObjectType.medicationDoseEventType(), frequency: .immediate,
                serialize: Serializers.medicationDoseEvent, enrich: { try await $0.enrichDoseEvent($1, $2) }
            ))
        }
        for entry in HealthKitCatalog.otherIdentifiers where entry.kind == "HKCorrelationTypeIdentifier" {
            guard isAvailable(entry.minimumOS),
                  let type = HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: entry.identifier))
            else { continue }
            types.append(SyncedType(
                key: entry.key, displayName: "\(entry.name) (correlation)", group: group(forSection: entry.section),
                sampleType: type, frequency: .immediate, access: .viaComponents,
                serialize: Serializers.correlation(type: entry.key)
            ))
        }
        return types
    }()

    // MARK: - Public surface

    static let all: [SyncedType] = {
        let combined = specialTypes + categoryTypes + quantityTypes
        let rank = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { ($1, $0) })
        // Stable sort: registry order within a group.
        return combined.enumerated().sorted { a, b in
            let ra = rank[a.element.group] ?? groupOrder.count
            let rb = rank[b.element.group] ?? groupOrder.count
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }()

    static var snapshots: [SnapshotSource] { Snapshots.all }

    /// Group names in display order, for UI sections.
    static let groups: [String] = {
        let present = Set(all.map(\.group) + Snapshots.all.map(\.group))
        return groupOrder.filter(present.contains)
    }()

    private static let byKey: [String: SyncedType] = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byIdentifier: [String: SyncedType] = Dictionary(
        all.map { ($0.sampleType.identifier, $0) }, uniquingKeysWith: { first, _ in first })

    static func type(for key: String) -> SyncedType? {
        byKey[key]
    }

    static func type(for sampleType: HKSampleType) -> SyncedType? {
        byIdentifier[sampleType.identifier]
    }

    /// Everything requestAuthorization should be asked to read, before
    /// HealthAuthorization drops what this OS refuses.
    static var readTypes: Set<HKObjectType> {
        var types = Set(all.filter { $0.access == .read }.map { $0.sampleType as HKObjectType })
        for source in Snapshots.all {
            types.formUnion(source.readTypes)
        }
        return types
    }

    /// Types granted object by object from a user tap.
    static var perObjectTypes: [(key: String, displayName: String, type: HKObjectType)] {
        var out = all.filter { $0.access == .perObject }.map { ($0.key, $0.displayName, $0.sampleType as HKObjectType) }
        for source in Snapshots.all {
            if let type = source.perObjectType {
                out.append((source.key, source.displayName, type))
            }
        }
        return out
    }

    /// SDK identifiers this build declares but doesn't sync, with the reason,
    /// for the coverage list in Settings and the docs.
    static var skipped: [(identifier: String, reason: String)] {
        var out: [(String, String)] = []
        for entry in HealthKitCatalog.quantities where byKey[entry.key] == nil {
            out.append((entry.identifier, isAvailable(entry.minimumOS) ? "unit \(entry.unit) unusable" : "needs a newer iOS"))
        }
        for entry in HealthKitCatalog.categories where byKey[entry.key] == nil {
            out.append((entry.identifier, "needs a newer iOS"))
        }
        for entry in HealthKitCatalog.otherIdentifiers where byKey[entry.key] == nil {
            switch entry.kind {
            case "HKDocumentTypeIdentifier":
                out.append((entry.identifier, "clinical document: each document needs its own approval sheet"))
            default:
                out.append((entry.identifier, "needs a newer iOS"))
            }
        }
        return out
    }
}
