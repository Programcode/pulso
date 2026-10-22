import AppIntents
import Foundation

/// A syncable type as Shortcuts sees it (sample types and snapshots).
struct HealthTypeEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Health Data Type"
    static var defaultQuery = HealthTypeQuery()

    var id: String
    var name: String
    var group: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(group) · \(id)")
    }

    static var all: [HealthTypeEntity] {
        TypeRegistry.snapshots.map { HealthTypeEntity(id: $0.key, name: $0.displayName, group: $0.group) }
            + TypeRegistry.all.map { HealthTypeEntity(id: $0.key, name: $0.displayName, group: $0.group) }
    }
}

struct HealthTypeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HealthTypeEntity] {
        let wanted = Set(identifiers)
        return HealthTypeEntity.all.filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [HealthTypeEntity] {
        HealthTypeEntity.all.filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [HealthTypeEntity] {
        HealthTypeEntity.all
    }
}

/// Incremental sync, optionally limited to some types. With a date range it
/// re-sends what HealthKit holds in that range instead (anchors untouched).
struct SyncHealthDataIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Health Data"
    static var description = IntentDescription(
        "Sends new Apple Health data to your destinations. Pick types to limit it; add a date range to re-send that period."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Types", description: "Leave empty for every enabled type.")
    var types: [HealthTypeEntity]?

    @Parameter(title: "From")
    var start: Date?

    @Parameter(title: "Until")
    var end: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Sync \(\.$types) from \(\.$start) until \(\.$end)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = AppServices.shared
        services.launchIfNeeded()
        let keys = types.map { Set($0.map(\.id)) }
        let summary: String
        if start != nil || end != nil {
            summary = await services.resend(keys: keys, start: start, end: end, reason: .intent("Sync Health Data"))
        } else {
            summary = await services.syncFromIntent(keys: keys)
        }
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

/// Re-sends history (all of it by default) for some or all types. Anchors
/// are left alone; receivers dedupe by uuid.
struct BackfillHealthDataIntent: AppIntent {
    static var title: LocalizedStringResource = "Backfill Health Data"
    static var description = IntentDescription(
        "Re-sends Apple Health history to your destinations. Large histories take a while: keep the phone unlocked."
    )
    /// A full backfill outlives background time; running in the foreground
    /// keeps HealthKit readable and the app alive.
    static var openAppWhenRun = true

    @Parameter(title: "Types", description: "Leave empty for every enabled type.")
    var types: [HealthTypeEntity]?

    @Parameter(title: "Since", description: "Leave empty for all history.")
    var start: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Backfill \(\.$types) since \(\.$start)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = AppServices.shared
        services.launchIfNeeded()
        let summary = await services.resend(
            keys: types.map { Set($0.map(\.id)) }, start: start, end: nil, reason: .intent("Backfill")
        )
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct GetSyncStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Sync Status"
    static var description = IntentDescription("Reports when Pulso last synced, what it sent, and what is still queued.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = await AppServices.shared.statusReport()
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct PulsoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncHealthDataIntent(),
            phrases: ["Sync health data with \(.applicationName)", "\(.applicationName) sync"],
            shortTitle: "Sync Health Data",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: BackfillHealthDataIntent(),
            phrases: ["Backfill health data with \(.applicationName)"],
            shortTitle: "Backfill",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: GetSyncStatusIntent(),
            phrases: ["\(.applicationName) sync status"],
            shortTitle: "Sync Status",
            systemImageName: "checkmark.circle"
        )
    }
}
