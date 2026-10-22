import HealthKit

/// Stable, human-readable names for workout activity types, matching the
/// Swift case names (generated from the SDK's HKWorkoutActivityType). Types
/// this build doesn't know (newer OS) serialize as "activity_<rawValue>"
/// rather than being silently merged into "other".
enum WorkoutActivityName {
    static func name(for activity: HKWorkoutActivityType) -> String {
        HealthKitCatalog.enumNames["HKWorkoutActivityType"]?[Int(activity.rawValue)] ?? "activity_\(activity.rawValue)"
    }
}
