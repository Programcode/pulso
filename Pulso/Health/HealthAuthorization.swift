import Foundation
import HealthKit

/// HealthKit raises an Objective-C exception (which would crash the app)
/// when an authorization request names a type it won't let third-party
/// apps read on this OS. The read set is therefore probed first and any
/// refused type dropped, so one bad identifier can't cost all the others.
enum HealthAuthorization {
    struct ReadSet {
        let accepted: Set<HKObjectType>
        /// Identifier -> the exception HealthKit raised for it alone.
        let rejected: [String: String]
    }

    static let rejectedKey = "auth.rejectedTypes"

    /// Types refused on the last probe, for SyncEngine to skip.
    static func lastRejected() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: rejectedKey) ?? [])
    }

    /// Probes `candidates` as one request; on an exception, splits the set
    /// and probes the halves until each refused type is isolated.
    static func readSet(_ candidates: Set<HKObjectType>, store: HKHealthStore) -> ReadSet {
        var rejected: [String: String] = [:]
        func accepted(_ types: [HKObjectType]) -> [HKObjectType] {
            guard !types.isEmpty else { return [] }
            guard let failure = probe(types, store: store) else { return types }
            if types.count == 1 {
                rejected[types[0].identifier] = failure
                return []
            }
            let middle = types.count / 2
            return accepted(Array(types[..<middle])) + accepted(Array(types[middle...]))
        }
        let ordered = candidates.sorted { $0.identifier < $1.identifier }
        var kept = accepted(ordered)
        // Some types are only accepted alongside another (heartbeat series
        // needs HRV in the same request), so an isolated refusal gets one
        // more try next to everything that passed.
        for identifier in rejected.keys.sorted() {
            guard let type = ordered.first(where: { $0.identifier == identifier }),
                  probe(kept + [type], store: store) == nil else { continue }
            kept.append(type)
            rejected[identifier] = nil
        }
        let result = ReadSet(accepted: Set(kept), rejected: rejected)
        UserDefaults.standard.set(result.rejected.keys.sorted(), forKey: rejectedKey)
        return result
    }

    /// nil when HealthKit accepts the set; otherwise the exception text.
    private static func probe(_ types: [HKObjectType], store: HKHealthStore) -> String? {
        do {
            try ObjC.catching {
                store.getRequestStatusForAuthorization(toShare: [], read: Set(types)) { _, _ in }
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    static func requestStatus(_ types: Set<HKObjectType>, store: HKHealthStore) async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try ObjC.catching {
                    store.getRequestStatusForAuthorization(toShare: [], read: types) { status, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: status)
                        }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func request(_ types: Set<HKObjectType>, store: HKHealthStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try ObjC.catching {
                    store.requestAuthorization(toShare: [], read: types) { _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
