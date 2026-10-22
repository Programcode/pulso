import CoreLocation
import CryptoKit
import Foundation
import HealthKit

/// Follow-up queries for samples whose payload doesn't live on the sample
/// object itself (route locations, heartbeats, ECG voltages, workout links),
/// and the enrich steps built on them. An enrich step throws rather than
/// ship a partial sample: the type's anchor then stays put and the sample
/// is read again on the next pass.
struct HealthQueries: @unchecked Sendable {
    let store: HKHealthStore

    func samples(_ type: HKSampleType, predicate: NSPredicate?, limit: Int? = nil) async throws -> [HKSample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: type, predicate: predicate)],
            sortDescriptors: [],
            limit: limit
        )
        return try await descriptor.result(for: store)
    }

    // MARK: - Series payloads

    func locations(of route: HKWorkoutRoute) async throws -> [CLLocation] {
        let collector = Collector<CLLocation>()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error { return collector.fail(error, continuation) }
                collector.append(contentsOf: locations ?? [])
                if done { collector.finish(continuation) }
            }
            store.execute(query)
        }
    }

    struct Beat: Sendable {
        let secondsFromStart: TimeInterval
        let precededByGap: Bool
    }

    func beats(of series: HKHeartbeatSeriesSample) async throws -> [Beat] {
        let collector = Collector<Beat>()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKHeartbeatSeriesQuery(heartbeatSeries: series) { _, time, gap, done, error in
                if let error { return collector.fail(error, continuation) }
                collector.append(Beat(secondsFromStart: time, precededByGap: gap))
                if done { collector.finish(continuation) }
            }
            store.execute(query)
        }
    }

    struct Voltage: Sendable {
        let secondsFromStart: TimeInterval
        let microvolts: Double
    }

    func voltages(of ecg: HKElectrocardiogram) async throws -> [Voltage] {
        let collector = Collector<Voltage>()
        let microvolts = HKUnit.voltUnit(with: .micro)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKElectrocardiogramQuery(ecg) { _, result in
                switch result {
                case .measurement(let measurement):
                    if let quantity = measurement.quantity(for: .appleWatchSimilarToLeadI),
                       quantity.is(compatibleWith: microvolts) {
                        collector.append(Voltage(
                            secondsFromStart: measurement.timeSinceSampleStart,
                            microvolts: quantity.doubleValue(for: microvolts)
                        ))
                    }
                case .done:
                    collector.finish(continuation)
                case .error(let error):
                    collector.fail(error, continuation)
                @unknown default:
                    collector.fail(CocoaError(.featureUnsupported), continuation)
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Enrich steps

    /// Workout → the routes and heart-rate samples that belong to it.
    /// Heart rate is linked by association when the recording app made
    /// one, otherwise by the workout's time range.
    func enrichWorkout(_ dto: SampleDTO, _ sample: HKSample) async throws -> SampleDTO {
        guard let workout = sample as? HKWorkout else { return dto }
        var dto = dto
        var details = dto.details ?? [:]
        let fromWorkout = HKQuery.predicateForObjects(from: workout)
        let routes = try await optionalLink { try await samples(HKSeriesType.workoutRoute(), predicate: fromWorkout) }
        if !routes.isEmpty {
            details["routeUUIDs"] = .array(routes.map { .string($0.uuid.uuidString) })
        }
        let heartRate = HKQuantityType(.heartRate)
        var heartRateSamples = try await optionalLink { try await samples(heartRate, predicate: fromWorkout) }
        var link = "associated"
        if heartRateSamples.isEmpty {
            let during = HKQuery.predicateForSamples(
                withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
            heartRateSamples = try await optionalLink { try await samples(heartRate, predicate: during) }
            link = "timeRange"
        }
        if !heartRateSamples.isEmpty {
            details["heartRateSampleUUIDs"] = .array(heartRateSamples.map { .string($0.uuid.uuidString) })
            details["heartRateLink"] = .string(link)
        }
        dto.details = details.isEmpty ? nil : details
        return dto
    }

    /// Links are extras: when the linked type isn't authorized the workout
    /// still syncs without them. Any other failure (phone locked, ...)
    /// throws, so the workout is read again with its links next time.
    private func optionalLink(_ query: () async throws -> [HKSample]) async throws -> [HKSample] {
        do {
            return try await query()
        } catch let error as HKError where error.code == .errorAuthorizationNotDetermined
            || error.code == .errorAuthorizationDenied {
            return []
        }
    }

    static let locationFields: JSONValue = [
        "secondsFromStart", "latitude", "longitude", "altitude", "horizontalAccuracy",
        "verticalAccuracy", "speed", "course", "speedAccuracy", "courseAccuracy",
    ]

    func enrichRoute(_ dto: SampleDTO, _ sample: HKSample) async throws -> SampleDTO {
        guard let route = sample as? HKWorkoutRoute else { return dto }
        var dto = dto
        var details = dto.details ?? [:]
        let locations = try await locations(of: route)
        details["locationFields"] = Self.locationFields
        details["locations"] = .array(locations.map { location in
            .array([
                rounded(location.timestamp.timeIntervalSince(route.startDate), 3),
                rounded(location.coordinate.latitude, 7),
                rounded(location.coordinate.longitude, 7),
                rounded(location.altitude, 2),
                rounded(location.horizontalAccuracy, 2),
                rounded(location.verticalAccuracy, 2),
                rounded(location.speed, 3),
                rounded(location.course, 2),
                rounded(location.speedAccuracy, 3),
                rounded(location.courseAccuracy, 2),
            ])
        })
        if let workout = try? await parentWorkout(of: route) {
            details["workoutUUID"] = .string(workout)
        }
        dto.details = details
        return dto
    }

    /// Routes don't point at their workout; the workout (saved first, the
    /// route attached after) is found among those overlapping the route.
    private func parentWorkout(of route: HKWorkoutRoute) async throws -> String? {
        let window = HKQuery.predicateForSamples(
            withStart: route.startDate.addingTimeInterval(-3600), end: route.endDate.addingTimeInterval(3600))
        for case let workout as HKWorkout in try await samples(.workoutType(), predicate: window) {
            let routes = try await samples(HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: workout))
            if routes.contains(where: { $0.uuid == route.uuid }) {
                return workout.uuid.uuidString
            }
        }
        return nil
    }

    func enrichHeartbeats(_ dto: SampleDTO, _ sample: HKSample) async throws -> SampleDTO {
        guard let series = sample as? HKHeartbeatSeriesSample else { return dto }
        var dto = dto
        var details = dto.details ?? [:]
        let beats = try await beats(of: series)
        details["beatFields"] = ["secondsFromStart", "precededByGap"]
        details["beats"] = .array(beats.map { .array([rounded($0.secondsFromStart, 4), .bool($0.precededByGap)]) })
        dto.details = details
        return dto
    }

    func enrichElectrocardiogram(_ dto: SampleDTO, _ sample: HKSample) async throws -> SampleDTO {
        guard let ecg = sample as? HKElectrocardiogram else { return dto }
        var dto = dto
        var details = dto.details ?? [:]
        let voltages = try await voltages(of: ecg)
        details["lead"] = "appleWatchSimilarToLeadI"
        details["voltageFields"] = ["secondsFromStart", "microvolts"]
        details["voltages"] = .array(voltages.map { .array([rounded($0.secondsFromStart, 4), rounded($0.microvolts, 3)]) })
        dto.details = details
        return dto
    }

    @available(iOS 26.0, *)
    func enrichDoseEvent(_ dto: SampleDTO, _ sample: HKSample) async throws -> SampleDTO {
        guard let event = sample as? HKMedicationDoseEvent else { return dto }
        var dto = dto
        // Names need per-object medication access; without it the concept
        // key alone still identifies the medication.
        let medications = await MedicationListCache.shared.list { try await userAnnotatedMedications() }
        if let match = medications.first(where: { $0.medication.identifier == event.medicationConceptIdentifier }) {
            var details = dto.details ?? [:]
            details["medicationName"] = .string(match.medication.displayText)
            if let nickname = match.nickname { details["medicationNickname"] = .string(nickname) }
            dto.details = details
        }
        return dto
    }

    @available(iOS 26.0, *)
    func userAnnotatedMedications() async throws -> [HKUserAnnotatedMedication] {
        let collector = Collector<HKUserAnnotatedMedication>()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKUserAnnotatedMedicationQuery(predicate: nil, limit: HKObjectQueryNoLimit) { _, medication, done, error in
                if let error { return collector.fail(error, continuation) }
                if let medication { collector.append(medication) }
                if done { collector.finish(continuation) }
            }
            store.execute(query)
        }
    }

    private func rounded(_ value: Double, _ digits: Int) -> JSONValue {
        guard value.isFinite else { return .null }
        let scale = pow(10, Double(digits))
        return .number((value * scale).rounded() / scale)
    }
}

/// The medication list, read at most once a minute: a backfill enriches
/// thousands of dose events and each would otherwise query it again.
@available(iOS 26.0, *)
actor MedicationListCache {
    static let shared = MedicationListCache()
    private var cached: (at: Date, list: [HKUserAnnotatedMedication])?

    func list(_ load: () async throws -> [HKUserAnnotatedMedication]) async -> [HKUserAnnotatedMedication] {
        if let cached, Date().timeIntervalSince(cached.at) < 60 { return cached.list }
        let list = (try? await load()) ?? []
        cached = (Date(), list)
        return list
    }
}

/// A stable string for a medication concept. The identifier object exposes
/// only its domain publicly, so its archived form is hashed instead.
enum MedicationIdentity {
    @available(iOS 26.0, *)
    static func key(_ identifier: HKHealthConceptIdentifier) -> String {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true) else {
            return identifier.domain.rawValue
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(identifier.domain.rawValue):\(digest.prefix(24))"
    }
}

/// Gathers a streaming query's callbacks and resumes its continuation
/// exactly once, whichever of done / error arrives first.
private final class Collector<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    private var finished = false

    func append(_ item: Element) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    func append(contentsOf batch: [Element]) {
        lock.lock()
        defer { lock.unlock() }
        items.append(contentsOf: batch)
    }

    func finish(_ continuation: CheckedContinuation<[Element], Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: items)
    }

    func fail(_ error: Error, _ continuation: CheckedContinuation<[Element], Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(throwing: error)
    }
}
