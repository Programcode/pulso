import SwiftUI
import UniformTypeIdentifiers

/// Settings › Destinations: every place data goes, each with its own
/// queue and last response.
struct DestinationsSection: View {
    let services: AppServices

    var body: some View {
        @Bindable var settings = services.settings
        Section {
            ForEach($settings.destinations) { $destination in
                NavigationLink {
                    DestinationEditor(services: services, destination: $destination)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(destination.name)
                            if !destination.enabled {
                                Text("off").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(destination.kind.title) · \(destination.summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .onDelete { offsets in
                // Resolve first: each removal shifts the indices after it.
                let doomed = offsets.map { services.settings.destinations[$0] }
                for destination in doomed {
                    services.removeDestination(destination)
                }
            }
            Menu("Add Destination") {
                ForEach(Destination.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) {
                        services.settings.destinations.append(Destination(name: kind.title, kind: kind))
                    }
                }
            }
        } header: {
            Text("Destinations")
        } footer: {
            Text("Every enabled destination gets every batch, from its own queue: one being down never holds up the others. A destination that is off, or added later, doesn't get what was synced before; run the Backfill shortcut to send it history.")
        }
    }
}

struct DestinationEditor: View {
    let services: AppServices
    @Binding var destination: Destination

    @State private var bearer = ""
    @State private var hmac = ""
    @State private var mqttPassword = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var pickingFolder = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $destination.name)
                Toggle("Enabled", isOn: $destination.enabled)
                LabeledContent("Kind", value: destination.kind.title)
            }

            switch destination.kind {
            case .rest, .pulso, .homeAssistant:
                httpSections
            case .mqtt:
                mqttSection
            case .file:
                fileSection
            }

            Section {
                Button {
                    testing = true
                    testResult = nil
                    Task {
                        testResult = await services.testDestination(destination)
                        testing = false
                    }
                } label: {
                    HStack {
                        Text("Test")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || !destination.isConfigured)
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                }
                if let state = services.status.destinationStatus[destination.id] {
                    LabeledContent("Queued batches", value: "\(state.pending)")
                    LabeledContent("Delivered", value: "\(state.delivered)")
                    if let response = state.lastResponse {
                        LabeledContent("Last response") {
                            Text(response).font(.caption).lineLimit(3).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .navigationTitle(destination.name)
        .onAppear {
            bearer = destination.bearerToken ?? ""
            hmac = destination.hmacSecret ?? ""
            mqttPassword = destination.mqttPassword ?? ""
        }
        .onChange(of: destination) { _, _ in services.destinationsChanged() }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            let url: URL
            switch result {
            case .success(let picked):
                url = picked
            case .failure(let error):
                testResult = "Couldn't open that folder: \(error.localizedDescription)"
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                destination.folderBookmark = try url.bookmarkData()
                destination.folderName = url.lastPathComponent
            } catch {
                testResult = "Couldn't keep access to that folder: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var httpSections: some View {
        Section {
            TextField(urlPlaceholder, text: $destination.url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if destination.kind == .rest {
                Picker("Body", selection: $destination.format) {
                    Text("pulso.v2 envelope").tag(Destination.BodyFormat.envelope)
                    Text("Bare array (Pulso v1)").tag(Destination.BodyFormat.array)
                    Text("NDJSON").tag(Destination.BodyFormat.ndjson)
                }
                Toggle("Gzip body", isOn: $destination.gzip)
                Toggle("Ask <url>/latest on first sync", isOn: $destination.catchUp)
            }
        } header: {
            Text(destination.kind == .homeAssistant ? "Webhook" : "Endpoint")
        } footer: {
            Text(urlFooter)
        }

        if destination.kind != .homeAssistant {
            Section {
                SecureField("Bearer token", text: $bearer)
                    .onChange(of: bearer) { _, value in destination.bearerToken = value }
                SecureField("HMAC-SHA256 secret", text: $hmac)
                    .onChange(of: hmac) { _, value in destination.hmacSecret = value }
            } header: {
                Text("Authentication")
            } footer: {
                Text("Both optional. With a secret, each request carries X-Signature: sha256=<hex HMAC of the body as sent, after gzip>. Stored in the Keychain.")
            }
        }

        Section {
            ForEach($destination.headers) { $header in
                HStack {
                    TextField("Header", text: $header.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Value", text: $header.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .onDelete { destination.headers.remove(atOffsets: $0) }
            Button("Add Header") {
                destination.headers.append(.init(name: "", value: ""))
            }
        } header: {
            Text("Custom Headers")
        }
    }

    private var urlPlaceholder: String {
        switch destination.kind {
        case .pulso: "http://100.x.y.z:8787"
        case .homeAssistant: "https://homeassistant.local:8123/api/webhook/<id>"
        default: "https://example.com/ingest"
        }
    }

    private var urlFooter: String {
        switch destination.kind {
        case .pulso:
            "Base URL of a server speaking the original Pulso protocol: batches go to <url>/ingest."
        case .homeAssistant:
            "Each batch triggers the webhook with a pulso.v2 envelope (uncompressed, at most 200 items, long series replaced by their length)."
        default:
            "Each batch is POSTed here."
        }
    }

    private var mqttSection: some View {
        Section {
            TextField("Broker host", text: $destination.mqttHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", value: $destination.mqttPort, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            Toggle("TLS", isOn: $destination.mqttTLS)
            TextField("Username", text: $destination.mqttUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $mqttPassword)
                .onChange(of: mqttPassword) { _, value in destination.mqttPassword = value }
            TextField("Topic prefix", text: $destination.mqttTopicPrefix)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Retain messages", isOn: $destination.mqttRetain)
        } header: {
            Text("Broker")
        } footer: {
            Text("QoS 1. Each batch publishes one JSON array per type to <prefix>/<type>; deletions go to <prefix>/deleted.")
        }
    }

    private var fileSection: some View {
        Section {
            LabeledContent("Folder", value: destination.folderName ?? "Pulso Export (On My iPhone)")
            Button("Choose Folder…") { pickingFolder = true }
            if destination.folderBookmark != nil {
                Button("Use the App's Own Folder", role: .destructive) {
                    destination.folderBookmark = nil
                    destination.folderName = nil
                }
            }
        } header: {
            Text("Folder")
        } footer: {
            Text("Appends one JSON object per line to pulso-<date>.ndjson. Pick a folder in iCloud Drive to have it on your Mac.")
        }
    }
}
