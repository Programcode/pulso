import Foundation
import Observation

enum SettingsKeys {
    /// The single server URL from before destinations; read once to migrate.
    static let endpoint = "server.endpoint"
    static let enabledTypes = "types.enabled"
    static let tokenAccount = "server-token"
    static let outboxSequence = "outbox.seq"
    /// True from the moment a full re-import is requested until a sync pass
    /// covers every enabled type without error. While set, the /latest
    /// catch-up shortcut is disabled so the re-import cannot be defeated by
    /// an interleaved or resumed pass.
    static let reimportPending = "sync.reimportPending"
    static let destinations = "destinations.v1"
}

/// User configuration. The @Observable instance drives the UI; the static
/// accessors read the same storage (UserDefaults / Keychain, both
/// thread-safe) so background actors never touch the UI object.
@Observable
@MainActor
final class AppSettings {
    private var enabled: [String: Bool] {
        didSet { UserDefaults.standard.set(enabled, forKey: SettingsKeys.enabledTypes) }
    }

    /// Where data goes. Saved on every change; secrets are kept in the
    /// Keychain by Destination itself.
    var destinations: [Destination] {
        didSet { Self.storeDestinations(destinations) }
    }

    init() {
        Self.migrateLegacyEndpoint()
        enabled = Self.storedEnabled()
        destinations = Self.currentDestinations()
        // Rewrites the stored list once per launch, so a header value saved
        // in plain text by an earlier build moves to the Keychain.
        Self.storeDestinations(destinations)
    }

    /// Before destinations, Pulso had one server URL and token. A non-empty
    /// one becomes a "Pulso server" destination, once.
    nonisolated static func migrateLegacyEndpoint() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: SettingsKeys.destinations) == nil else { return }
        var migrated: [Destination] = []
        if let raw = defaults.string(forKey: SettingsKeys.endpoint), baseURL(from: raw) != nil {
            var destination = Destination(name: "Pulso server", kind: .pulso)
            destination.url = raw
            destination.bearerToken = Keychain.string(for: SettingsKeys.tokenAccount)
            migrated.append(destination)
        }
        storeDestinations(migrated)
    }

    /// Header values go to the Keychain; the list is saved with them blank.
    nonisolated static func storeDestinations(_ destinations: [Destination]) {
        var stripped = destinations
        for index in stripped.indices {
            for headerIndex in stripped[index].headers.indices {
                let header = stripped[index].headers[headerIndex]
                Keychain.set(header.value, for: stripped[index].headerValueAccount(header))
                stripped[index].headers[headerIndex].value = ""
            }
        }
        if let data = try? JSONEncoder().encode(stripped) {
            UserDefaults.standard.set(data, forKey: SettingsKeys.destinations)
        }
    }

    nonisolated static func currentDestinations() -> [Destination] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.destinations),
              var destinations = try? JSONDecoder().decode([Destination].self, from: data) else { return [] }
        for index in destinations.indices {
            for headerIndex in destinations[index].headers.indices {
                let header = destinations[index].headers[headerIndex]
                // A value saved in the list by an earlier build is kept until
                // the next save moves it to the Keychain.
                destinations[index].headers[headerIndex].value =
                    Keychain.string(for: destinations[index].headerValueAccount(header)) ?? header.value
            }
        }
        return destinations
    }

    nonisolated static func activeDestinations() -> [Destination] {
        currentDestinations().filter { $0.enabled && $0.isConfigured }
    }

    func isEnabled(_ key: String) -> Bool { enabled[key] ?? true }
    func setEnabled(_ key: String, _ value: Bool) { enabled[key] = value }

    // MARK: - Shared parsing / thread-safe accessors

    nonisolated static func baseURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }

    nonisolated static func currentEnabled(_ key: String) -> Bool {
        storedEnabled()[key] ?? true
    }

    nonisolated static func currentEnabledTypes() -> [SyncedType] {
        TypeRegistry.all.filter { currentEnabled($0.key) }
    }

    nonisolated static func currentEnabledSnapshots() -> [SnapshotSource] {
        TypeRegistry.snapshots.filter { currentEnabled($0.key) }
    }

    nonisolated private static func storedEnabled() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.enabledTypes) ?? [:])
            .compactMapValues { $0 as? Bool }
    }
}
