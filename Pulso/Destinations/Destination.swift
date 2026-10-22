import Foundation

/// One place health data goes. Several can be enabled at once; each has
/// its own durable queue, so a slow or broken one never holds up the rest.
/// Secrets (bearer token, HMAC secret, MQTT password) live in the Keychain
/// under the destination's id, never in this struct.
struct Destination: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Any HTTPS endpoint: POST of the pulso.v2 envelope (or a bare array).
        case rest
        /// A server speaking the original Pulso protocol (POST <base>/ingest).
        case pulso
        /// A Home Assistant webhook trigger.
        case homeAssistant
        /// An MQTT broker, one message per type per batch.
        case mqtt
        /// NDJSON files in a folder (Files app, iCloud Drive).
        case file

        var title: String {
            switch self {
            case .rest: "HTTPS / webhook"
            case .pulso: "Pulso server"
            case .homeAssistant: "Home Assistant webhook"
            case .mqtt: "MQTT"
            case .file: "File export (NDJSON)"
            }
        }
    }

    enum BodyFormat: String, Codable, CaseIterable, Sendable {
        /// {"schema":"pulso.v2","device":{...},"type":...,"items":[...]}
        case envelope
        /// The original Pulso body: a bare JSON array of items.
        case array
        /// One JSON object per line.
        case ndjson
    }

    /// Header values can be API keys, so they are kept in the Keychain:
    /// AppSettings stores them there and saves the list with values blank.
    struct Header: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var value: String

        init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var enabled = true

    // HTTP kinds
    var url = ""
    var format: BodyFormat = .envelope
    var gzip = true
    var headers: [Header] = []
    /// Ask <url>/latest what the server already has when a type has no
    /// anchor yet (fresh install), instead of re-sending all history.
    var catchUp = false

    // MQTT
    var mqttHost = ""
    var mqttPort = 8883
    var mqttTLS = true
    var mqttUsername = ""
    var mqttTopicPrefix = "pulso"
    var mqttRetain = false

    // File export: a security-scoped bookmark of a folder the user picked;
    // nil means the app's own Documents/Pulso Export folder.
    var folderBookmark: Data?
    var folderName: String?

    /// Every field falls back to its default when missing, so a field added
    /// in a later version can't make an existing list fail to decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name) ?? kind.title, kind: kind)
        id = try c.decode(UUID.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? url
        format = try c.decodeIfPresent(BodyFormat.self, forKey: .format) ?? format
        gzip = try c.decodeIfPresent(Bool.self, forKey: .gzip) ?? gzip
        headers = try c.decodeIfPresent([Header].self, forKey: .headers) ?? headers
        catchUp = try c.decodeIfPresent(Bool.self, forKey: .catchUp) ?? catchUp
        mqttHost = try c.decodeIfPresent(String.self, forKey: .mqttHost) ?? mqttHost
        mqttPort = try c.decodeIfPresent(Int.self, forKey: .mqttPort) ?? mqttPort
        mqttTLS = try c.decodeIfPresent(Bool.self, forKey: .mqttTLS) ?? mqttTLS
        mqttUsername = try c.decodeIfPresent(String.self, forKey: .mqttUsername) ?? mqttUsername
        mqttTopicPrefix = try c.decodeIfPresent(String.self, forKey: .mqttTopicPrefix) ?? mqttTopicPrefix
        mqttRetain = try c.decodeIfPresent(Bool.self, forKey: .mqttRetain) ?? mqttRetain
        folderBookmark = try c.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
    }

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
        switch kind {
        case .pulso:
            format = .array
            catchUp = true
        case .homeAssistant:
            gzip = false
        case .file:
            format = .ndjson
        case .rest, .mqtt:
            break
        }
    }

    /// Items per uploaded batch. Home Assistant automations choke on huge
    /// bodies; everything else takes the outbox's normal batches.
    var maxItemsPerBatch: Int? {
        kind == .homeAssistant ? 200 : nil
    }

    // MARK: - Secrets

    private func account(_ name: String) -> String { "destination.\(id.uuidString).\(name)" }

    var bearerToken: String? {
        get { Keychain.string(for: account("bearer")) }
        nonmutating set { Keychain.set(newValue, for: account("bearer")) }
    }

    var hmacSecret: String? {
        get { Keychain.string(for: account("hmac")) }
        nonmutating set { Keychain.set(newValue, for: account("hmac")) }
    }

    var mqttPassword: String? {
        get { Keychain.string(for: account("mqtt")) }
        nonmutating set { Keychain.set(newValue, for: account("mqtt")) }
    }

    func headerValueAccount(_ header: Header) -> String { account("header.\(header.id.uuidString)") }

    func deleteSecrets() {
        bearerToken = nil
        hmacSecret = nil
        mqttPassword = nil
        for header in headers {
            Keychain.set(nil, for: headerValueAccount(header))
        }
    }

    // MARK: - URLs

    /// Where batches are POSTed.
    var ingestURL: URL? {
        switch kind {
        case .pulso:
            AppSettings.baseURL(from: url).flatMap { URL(string: $0.absoluteString + "/ingest") }
        case .rest, .homeAssistant:
            Self.httpURL(url)
        case .mqtt, .file:
            nil
        }
    }

    /// GET target for the catch-up hint, when enabled.
    var latestURL: URL? {
        guard catchUp else { return nil }
        switch kind {
        case .pulso:
            return AppSettings.baseURL(from: url).flatMap { URL(string: $0.absoluteString + "/latest") }
        case .rest:
            return Self.httpURL(url).flatMap { url in
                var base = url.absoluteString
                while base.hasSuffix("/") { base.removeLast() }
                return URL(string: base + "/latest")
            }
        default:
            return nil
        }
    }

    /// A full endpoint URL, used exactly as typed (a trailing slash can be
    /// significant to the server).
    static func httpURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }

    var isConfigured: Bool {
        switch kind {
        case .rest, .pulso, .homeAssistant: ingestURL != nil
        case .mqtt: !mqttHost.trimmingCharacters(in: .whitespaces).isEmpty
        case .file: true
        }
    }

    var summary: String {
        switch kind {
        case .rest, .pulso, .homeAssistant: ingestURL?.absoluteString ?? "no URL"
        case .mqtt: "\(mqttHost):\(mqttPort) → \(mqttTopicPrefix)/<type>"
        case .file: folderName ?? "On My iPhone › Pulso › Pulso Export"
        }
    }
}
