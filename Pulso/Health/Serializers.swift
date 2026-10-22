import Foundation
import HealthKit

struct SerializerContext: Sendable {
    /// Read at serialize time so long-running backfills track timezone changes.
    let defaultTimeZone: @Sendable () -> TimeZone
    let formatter: TimestampFormatter

    static let live = SerializerContext(defaultTimeZone: { .current }, formatter: TimestampFormatter())

    func timestamp(_ date: Date) -> String {
        formatter.string(date, in: defaultTimeZone())
    }
}

enum Serializers {
    /// Metadata keys folded into protocol keys instead of passing through raw.
    private static let foldedMetadataKeys: Set<String> = [
        HKMetadataKeyTimeZone, HKMetadataKeySexualActivityProtectionUsed,
    ]

    /// Fields shared by every sample type. Timestamps keep the sample's own
    /// timezone when it recorded one (HKMetadataKeyTimeZone); otherwise the
    /// device timezone is used and `metadata.timeZone` stays absent so
    /// consumers can tell a recorded timezone from an assumed one.
    static func base(_ sample: HKSample, type: String, context: SerializerContext) -> SampleDTO {
        let recordedZone = (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap {
            TimeZone(identifier: $0) ?? TimeZone(abbreviation: $0)
        }
        let zone = recordedZone ?? context.defaultTimeZone()
        let revision = sample.sourceRevision
        var dto = SampleDTO(
            uuid: sample.uuid.uuidString,
            type: type,
            start: context.formatter.string(sample.startDate, in: zone),
            end: context.formatter.string(sample.endDate, in: zone),
            source: revision.source.name,
            sourceBundleId: revision.source.bundleIdentifier
        )
        dto.sourceVersion = revision.version
        dto.sourceProductType = revision.productType
        let os = revision.operatingSystemVersion
        if os.majorVersion > 0 {
            dto.sourceOSVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        }
        dto.device = device(sample.device)

        var metadata: [String: JSONValue] = [:]
        if let recordedZone { metadata["timeZone"] = .string(recordedZone.identifier) }
        if let protectionUsed = sample.metadata?[HKMetadataKeySexualActivityProtectionUsed] as? Bool {
            metadata["protectionUsed"] = .bool(protectionUsed)
        }
        for (key, value) in sample.metadata ?? [:] where !foldedMetadataKeys.contains(key) {
            metadata[key] = jsonValue(value, context: context)
        }
        dto.metadata = metadata.isEmpty ? nil : metadata
        return dto
    }

    static func device(_ device: HKDevice?) -> [String: JSONValue]? {
        guard let device else { return nil }
        let fields: [(String, String?)] = [
            ("name", device.name), ("manufacturer", device.manufacturer), ("model", device.model),
            ("hardwareVersion", device.hardwareVersion), ("firmwareVersion", device.firmwareVersion),
            ("softwareVersion", device.softwareVersion), ("localIdentifier", device.localIdentifier),
            ("udiDeviceIdentifier", device.udiDeviceIdentifier),
        ]
        var out: [String: JSONValue] = [:]
        for case let (key, value?) in fields where !value.isEmpty {
            out[key] = .string(value)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Quantities and categories

    /// `scale` multiplies the converted value before it goes on the wire.
    /// Used for HealthKit's percent types, which read as fractions (0–1)
    /// via HKUnit.percent(): scale 100 delivers human-scale 0–100 under a
    /// "%" unit label.
    static func quantity(
        type: String, unit: HKUnit, unitLabel: String, scale: Double = 1
    ) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        { sample, context in
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            var dto = base(quantitySample, type: type, context: context)
            dto.kind = "quantity"
            dto.unit = unitLabel
            if let value = number(quantitySample.quantity, unit, scale: scale) {
                dto.value = .number(value)
            } else {
                // A unit this build didn't expect: keep the reading rather than drop it.
                dto.value = .string(quantitySample.quantity.description)
                dto.unit = nil
            }
            var details: [String: JSONValue] = [:]
            if quantitySample.count > 1 {
                details["count"] = .number(Double(quantitySample.count))
            }
            if let discrete = quantitySample as? HKDiscreteQuantitySample, discrete.count > 1 {
                details["minimum"] = json(discrete.minimumQuantity, unit, scale: scale)
                details["maximum"] = json(discrete.maximumQuantity, unit, scale: scale)
                details["average"] = json(discrete.averageQuantity, unit, scale: scale)
                details["mostRecent"] = json(discrete.mostRecentQuantity, unit, scale: scale)
            }
            dto.details = details.isEmpty ? nil : details
            return dto
        }
    }

    /// The quantity in `unit`, or nil when the units aren't compatible —
    /// HealthKit raises an exception rather than failing on a mismatch.
    static func number(_ quantity: HKQuantity?, _ unit: HKUnit, scale: Double = 1) -> Double? {
        guard let quantity, quantity.is(compatibleWith: unit) else { return nil }
        return quantity.doubleValue(for: unit) * scale
    }

    static func json(_ quantity: HKQuantity?, _ unit: HKUnit, scale: Double = 1) -> JSONValue? {
        number(quantity, unit, scale: scale).map(JSONValue.number)
    }

    /// Generic category-sample serializer. `valueName` maps the raw category
    /// value to its wire name; returning nil omits `value` entirely (for
    /// types like mindfulSession whose value is notApplicable — the interval
    /// itself is the data).
    static func category(
        type: String, valueName: @escaping @Sendable (Int) -> String?
    ) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        { sample, context in
            guard let categorySample = sample as? HKCategorySample else { return nil }
            var dto = base(categorySample, type: type, context: context)
            dto.kind = "category"
            dto.value = valueName(categorySample.value).map(SampleValue.string)
            return dto
        }
    }

    /// Category serializer whose value names come from the SDK's enum for
    /// the type; nil `valueEnum` means the value is notApplicable.
    static func category(type: String, valueEnum: String?) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        category(type: type) { raw in
            valueEnum.map { enumName($0, raw) }
        }
    }

    /// Wire name of an enum value, or "value_<n>" for one this build doesn't know.
    static func enumName(_ enumName: String, _ rawValue: Int) -> String {
        HealthKitCatalog.enumNames[enumName]?[rawValue] ?? "value_\(rawValue)"
    }

    /// Value is notApplicable (the event itself is the data); the one
    /// meaningful HealthKit metadata field becomes metadata.protectionUsed.
    @Sendable
    static func sexualActivity(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        category(type: "sexualActivity", valueEnum: nil)(sample, context)
    }

    static func standHourName(_ rawValue: Int) -> String {
        enumName("HKCategoryValueAppleStandHour", rawValue)
    }

    @Sendable
    static func sleep(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        category(type: "sleepAnalysis", valueEnum: "HKCategoryValueSleepAnalysis")(sample, context)
    }

    static func sleepStageName(_ rawValue: Int) -> String {
        enumName("HKCategoryValueSleepAnalysis", rawValue)
    }

    // MARK: - Workouts

    @Sendable
    static func workout(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let workout = sample as? HKWorkout else { return nil }
        var dto = base(workout, type: "workout", context: context)
        dto.kind = "workout"
        dto.workoutActivityType = WorkoutActivityName.name(for: workout.workoutActivityType)
        dto.duration = workout.duration
        // Statistics first; legacy totals (pre-iOS-16 recordings) as fallback.
        // HealthKit synthesizes zero-valued statistics for legacy-total
        // workouts, so zero sums count as absent — otherwise they shadow the
        // real legacy value.
        dto.totalEnergyBurned = positiveSum(workout, .activeEnergyBurned, unit: .kilocalorie())
            ?? workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        dto.totalBasalEnergyBurned = positiveSum(workout, .basalEnergyBurned, unit: .kilocalorie())
        dto.totalDistance = distanceMeters(of: workout)

        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let heartRate = workout.statistics(for: HKQuantityType(.heartRate)) {
            dto.averageHeartRate = heartRate.averageQuantity()?.doubleValue(for: bpm)
            dto.minimumHeartRate = heartRate.minimumQuantity()?.doubleValue(for: bpm)
            dto.maximumHeartRate = heartRate.maximumQuantity()?.doubleValue(for: bpm)
        }

        var details: [String: JSONValue] = [:]
        if let events = workout.workoutEvents, !events.isEmpty {
            details["events"] = .array(events.map { workoutEvent($0, context: context) })
        }
        if !workout.workoutActivities.isEmpty {
            details["activities"] = .array(workout.workoutActivities.map { activity($0, context: context) })
        }
        let statistics = statisticsJSON(workout.allStatistics)
        if !statistics.isEmpty { details["statistics"] = .object(statistics) }
        dto.details = details.isEmpty ? nil : details
        return dto
    }

    static func workoutEvent(_ event: HKWorkoutEvent, context: SerializerContext) -> JSONValue {
        var out: [String: JSONValue] = [
            "type": .string(enumName("HKWorkoutEventType", event.type.rawValue)),
            "start": .string(context.timestamp(event.dateInterval.start)),
            "end": .string(context.timestamp(event.dateInterval.end)),
            "duration": .number(event.dateInterval.duration),
        ]
        if let metadata = event.metadata, !metadata.isEmpty {
            out["metadata"] = jsonValue(metadata, context: context)
        }
        return .object(out)
    }

    static func activity(_ activity: HKWorkoutActivity, context: SerializerContext) -> JSONValue {
        let configuration = activity.workoutConfiguration
        var out: [String: JSONValue] = [
            "uuid": .string(activity.uuid.uuidString),
            "activityType": .string(WorkoutActivityName.name(for: configuration.activityType)),
            "locationType": .string(enumName("HKWorkoutSessionLocationType", configuration.locationType.rawValue)),
            "start": .string(context.timestamp(activity.startDate)),
            "duration": .number(activity.duration),
        ]
        if let end = activity.endDate { out["end"] = .string(context.timestamp(end)) }
        if configuration.swimmingLocationType != .unknown {
            out["swimmingLocationType"] = .string(
                enumName("HKWorkoutSwimmingLocationType", configuration.swimmingLocationType.rawValue))
        }
        out["lapLengthMeters"] = json(configuration.lapLength, .meter())
        if let metadata = activity.metadata, !metadata.isEmpty {
            out["metadata"] = jsonValue(metadata, context: context)
        }
        if !activity.workoutEvents.isEmpty {
            out["events"] = .array(activity.workoutEvents.map { workoutEvent($0, context: context) })
        }
        let statistics = statisticsJSON(activity.allStatistics)
        if !statistics.isEmpty { out["statistics"] = .object(statistics) }
        return .object(out)
    }

    /// Per quantity type: sum / average / min / max / most recent, in the
    /// same unit that type's samples use on the wire.
    static func statisticsJSON(_ all: [HKQuantityType: HKStatistics]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (type, statistics) in all {
            guard let presentation = TypeRegistry.presentation(for: type) else { continue }
            let unit = presentation.unit
            let scale = presentation.scale
            var entry: [String: JSONValue] = ["unit": .string(presentation.label)]
            entry["sum"] = json(statistics.sumQuantity(), unit, scale: scale)
            entry["average"] = json(statistics.averageQuantity(), unit, scale: scale)
            entry["minimum"] = json(statistics.minimumQuantity(), unit, scale: scale)
            entry["maximum"] = json(statistics.maximumQuantity(), unit, scale: scale)
            entry["mostRecent"] = json(statistics.mostRecentQuantity(), unit, scale: scale)
            if entry.count > 1 { out[presentation.key] = .object(entry) }
        }
        return out
    }

    private static let distanceTypes: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        .distanceWheelchair, .distanceDownhillSnowSports,
    ]

    private static func distanceMeters(of workout: HKWorkout) -> Double? {
        for identifier in distanceTypes {
            if let meters = positiveSum(workout, identifier, unit: .meter()) {
                return meters
            }
        }
        return workout.totalDistance?.doubleValue(for: .meter())
    }

    private static func positiveSum(
        _ workout: HKWorkout, _ identifier: HKQuantityTypeIdentifier, unit: HKUnit
    ) -> Double? {
        guard let sum = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity() else { return nil }
        let value = sum.doubleValue(for: unit)
        return value > 0 ? value : nil
    }

    // MARK: - Series and other sample classes

    /// Route, heartbeat and ECG samples: the bulk data (locations, beats,
    /// voltages) is added by the type's enrich step, which needs a query.
    static func plain(type: String, kind: String) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        { sample, context in
            var dto = base(sample, type: type, context: context)
            dto.kind = kind
            if let series = sample as? HKSeriesSample {
                dto.value = .number(Double(series.count))
                dto.unit = "count"
            }
            return dto
        }
    }

    @Sendable
    static func electrocardiogram(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let ecg = sample as? HKElectrocardiogram else { return nil }
        var dto = base(ecg, type: "electrocardiogram", context: context)
        dto.kind = "electrocardiogram"
        let classification = enumName("HKElectrocardiogramClassification", ecg.classification.rawValue)
        dto.value = .string(classification)
        var details: [String: JSONValue] = [
            "classification": .string(classification),
            "symptomsStatus": .string(enumName("HKElectrocardiogramSymptomsStatus", ecg.symptomsStatus.rawValue)),
            "numberOfVoltageMeasurements": .number(Double(ecg.numberOfVoltageMeasurements)),
        ]
        details["averageHeartRate"] = json(ecg.averageHeartRate, .count().unitDivided(by: .minute()))
        details["samplingFrequencyHz"] = json(ecg.samplingFrequency, .hertz())
        dto.details = details
        return dto
    }

    @Sendable
    static func audiogram(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let audiogram = sample as? HKAudiogramSample else { return nil }
        var dto = base(audiogram, type: "audiogram", context: context)
        dto.kind = "audiogram"
        let dBHL = HKUnit.decibelHearingLevel()
        let points: [JSONValue] = audiogram.sensitivityPoints.map { point in
            var out: [String: JSONValue] = [:]
            out["frequencyHz"] = json(point.frequency, .hertz())
            if #available(iOS 18.1, *) {
                out["tests"] = .array(point.tests.map { test in
                    var entry: [String: JSONValue] = [
                        "side": .string(enumName("HKAudiogramSensitivityTestSide", test.side.rawValue)),
                        "conductionType": .string(enumName("HKAudiogramConductionType", test.type.rawValue)),
                        "masked": .bool(test.masked),
                    ]
                    entry["sensitivityDBHL"] = json(test.sensitivity, dBHL)
                    if let range = test.clampingRange {
                        entry["clampingLowerDBHL"] = json(range.lowerBound, dBHL)
                        entry["clampingUpperDBHL"] = json(range.upperBound, dBHL)
                    }
                    return .object(entry)
                })
            } else {
                out["leftEarDBHL"] = json(point.leftEarSensitivity, dBHL)
                out["rightEarDBHL"] = json(point.rightEarSensitivity, dBHL)
            }
            return .object(out)
        }
        dto.details = ["points": .array(points)]
        return dto
    }

    @available(iOS 18.0, *)
    @Sendable
    static func stateOfMind(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let state = sample as? HKStateOfMind else { return nil }
        var dto = base(state, type: "stateOfMind", context: context)
        dto.kind = "stateOfMind"
        dto.value = .number(state.valence)
        // labels and associations are NS_REFINED_FOR_SWIFT; KVC reads the
        // underlying NSNumber arrays without depending on the overlay's shape.
        let labels = (state.value(forKey: "labels") as? [NSNumber]) ?? []
        let associations = (state.value(forKey: "associations") as? [NSNumber]) ?? []
        dto.details = [
            "kind": .string(enumName("HKStateOfMindKind", state.kind.rawValue)),
            "valence": .number(state.valence),
            "valenceClassification": .string(
                enumName("HKStateOfMindValenceClassification", state.valenceClassification.rawValue)),
            "labels": .array(labels.map { .string(enumName("HKStateOfMindLabel", $0.intValue)) }),
            "associations": .array(associations.map { .string(enumName("HKStateOfMindAssociation", $0.intValue)) }),
        ]
        return dto
    }

    /// GAD-7 and PHQ-9 questionnaires: the score is the value; risk and
    /// per-question answers go in details.
    @available(iOS 18.0, *)
    static func scoredAssessment(type: String, enumPrefix: String) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        { sample, context in
            guard let assessment = sample as? HKScoredAssessment else { return nil }
            var dto = base(assessment, type: type, context: context)
            dto.kind = "scoredAssessment"
            dto.value = .number(Double(assessment.score))
            var details: [String: JSONValue] = ["score": .number(Double(assessment.score))]
            if assessment.responds(to: Selector(("risk"))), let risk = assessment.value(forKey: "risk") as? NSNumber {
                details["risk"] = .string(enumName("\(enumPrefix)Risk", risk.intValue))
            }
            if assessment.responds(to: Selector(("answers"))),
               let answers = assessment.value(forKey: "answers") as? [NSNumber] {
                details["answers"] = .array(answers.map { .string(enumName("\(enumPrefix)Answer", $0.intValue)) })
            }
            dto.details = details
            return dto
        }
    }

    @Sendable
    static func visionPrescription(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let prescription = sample as? HKVisionPrescription else { return nil }
        var dto = base(prescription, type: "visionPrescription", context: context)
        dto.kind = "visionPrescription"
        let prescriptionType = enumName("HKVisionPrescriptionType", Int(prescription.prescriptionType.rawValue))
        dto.value = .string(prescriptionType)
        var details: [String: JSONValue] = [
            "prescriptionType": .string(prescriptionType),
            "dateIssued": .string(context.timestamp(prescription.dateIssued)),
        ]
        if let expiration = prescription.expirationDate {
            details["expirationDate"] = .string(context.timestamp(expiration))
        }
        if let glasses = prescription as? HKGlassesPrescription {
            details["rightEye"] = glasses.rightEye.map(lens)
            details["leftEye"] = glasses.leftEye.map(lens)
        } else if let contacts = prescription as? HKContactsPrescription {
            details["brand"] = .string(contacts.brand)
            details["rightEye"] = contacts.rightEye.map(lens)
            details["leftEye"] = contacts.leftEye.map(lens)
        }
        dto.details = details
        return dto
    }

    private static func lens(_ spec: HKLensSpecification) -> JSONValue {
        let diopter = HKUnit.diopter()
        let degrees = HKUnit.degreeAngle()
        let mm = HKUnit.meterUnit(with: .milli)
        var out: [String: JSONValue] = [:]
        out["sphere"] = json(spec.sphere, diopter)
        out["cylinder"] = json(spec.cylinder, diopter)
        out["axisDegrees"] = json(spec.axis, degrees)
        out["addPower"] = json(spec.addPower, diopter)
        if let glasses = spec as? HKGlassesLensSpecification {
            out["vertexDistanceMM"] = json(glasses.vertexDistance, mm)
            out["farPupillaryDistanceMM"] = json(glasses.farPupillaryDistance, mm)
            out["nearPupillaryDistanceMM"] = json(glasses.nearPupillaryDistance, mm)
            if let prism = glasses.prism {
                var p: [String: JSONValue] = [
                    "verticalBase": .string(enumName("HKPrismBase", prism.verticalBase.rawValue)),
                    "horizontalBase": .string(enumName("HKPrismBase", prism.horizontalBase.rawValue)),
                    "eye": .string(enumName("HKVisionEye", prism.eye.rawValue)),
                ]
                p["amount"] = json(prism.amount, .prismDiopter())
                p["angleDegrees"] = json(prism.angle, degrees)
                p["verticalAmount"] = json(prism.verticalAmount, .prismDiopter())
                p["horizontalAmount"] = json(prism.horizontalAmount, .prismDiopter())
                out["prism"] = .object(p)
            }
        }
        if let contacts = spec as? HKContactsLensSpecification {
            out["baseCurveMM"] = json(contacts.baseCurve, mm)
            out["diameterMM"] = json(contacts.diameter, mm)
        }
        return .object(out)
    }

    @available(iOS 26.0, *)
    @Sendable
    static func medicationDoseEvent(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let event = sample as? HKMedicationDoseEvent else { return nil }
        var dto = base(event, type: "medicationDoseEvent", context: context)
        dto.kind = "medicationDoseEvent"
        let status = enumName("HKMedicationDoseEventLogStatus", event.logStatus.rawValue)
        var details: [String: JSONValue] = [
            "logStatus": .string(status),
            "scheduleType": .string(enumName("HKMedicationDoseEventScheduleType", event.scheduleType.rawValue)),
            "medicationConcept": .string(MedicationIdentity.key(event.medicationConceptIdentifier)),
        ]
        if let scheduled = event.scheduledDate { details["scheduledDate"] = .string(context.timestamp(scheduled)) }
        // NS_REFINED_FOR_SWIFT quantities, read through KVC as NSNumber.
        if let dose = event.value(forKey: "doseQuantity") as? NSNumber {
            details["doseQuantity"] = .number(dose.doubleValue)
            dto.value = .number(dose.doubleValue)
            dto.unit = event.unit.unitString
        } else {
            dto.value = .string(status)
        }
        if let scheduledDose = event.value(forKey: "scheduledDoseQuantity") as? NSNumber {
            details["scheduledDoseQuantity"] = .number(scheduledDose.doubleValue)
        }
        details["unit"] = .string(event.unit.unitString)
        dto.details = details
        return dto
    }

    /// Blood pressure and food correlations: the member samples (also
    /// synced on their own) are listed with their values for convenience.
    static func correlation(type: String) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        { sample, context in
            guard let correlation = sample as? HKCorrelation else { return nil }
            var dto = base(correlation, type: type, context: context)
            dto.kind = "correlation"
            let members: [JSONValue] = correlation.objects.compactMap { member in
                guard let memberType = TypeRegistry.type(for: member.sampleType),
                      let memberDTO = memberType.serialize(member, context) else { return nil }
                var out: [String: JSONValue] = ["uuid": .string(memberDTO.uuid), "type": .string(memberDTO.type)]
                switch memberDTO.value {
                case .number(let n)?: out["value"] = .number(n)
                case .string(let s)?: out["value"] = .string(s)
                case nil: break
                }
                if let unit = memberDTO.unit { out["unit"] = .string(unit) }
                return .object(out)
            }
            dto.details = ["objects": .array(members)]
            return dto
        }
    }

    // MARK: - Metadata values

    /// Strings, numbers, and booleans pass through natively; arrays and
    /// dictionaries recurse; HKQuantity, dates, and anything else are
    /// stringified.
    static func jsonValue(_ value: Any, context: SerializerContext) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let date as Date:
            return .string(context.timestamp(date))
        case let array as [Any]:
            return .array(array.map { jsonValue($0, context: context) })
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues { jsonValue($0, context: context) })
        default:
            return .string(String(describing: value))
        }
    }
}
