import SwiftUI

struct StatusView: View {
    let services: AppServices

    private var status: AppStatus { services.status }

    var body: some View {
        NavigationStack {
            List {
                if status.authNeeded {
                    Section {
                        Button {
                            Task { await services.requestHealthAccess() }
                        } label: {
                            Label("Grant Health Access", systemImage: "heart.text.square")
                                .font(.headline)
                        }
                    } footer: {
                        Text("Pulso only asks to read the types listed below. iOS never reveals what you granted — only your data (or its absence) does.")
                    }
                }

                if !services.settings.destinations.contains(where: { $0.enabled && $0.isConfigured }) {
                    Section {
                        Label("Add a destination in Settings", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        Task { await services.syncNow(.manual) }
                    } label: {
                        HStack {
                            if status.syncing {
                                ProgressView()
                                    .padding(.trailing, 4)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(status.syncing ? "Syncing…" : "Sync Now")
                                .font(.headline)
                        }
                    }
                    .disabled(status.syncing)
                } footer: {
                    if status.needsInitialImport {
                        Text("First sync imports your full history. Keep the app open and unlocked until it finishes — progress is saved continuously, so interrupting is safe.")
                    }
                }

                Section {
                    LabeledContent("Types with data", value: "\(typesWithData.count) of \(enabledKeys.count) enabled")
                } footer: {
                    Text("Types appear below once something was delivered. HealthKit won't say whether an empty type is unauthorized or simply has no data (Health app → Sharing).")
                }

                ForEach(TypeRegistry.groups, id: \.self) { group in
                    let rows = rowsWithData(in: group)
                    if !rows.isEmpty {
                        Section(group) {
                            ForEach(rows) { row in
                                typeRow(key: row.key, name: row.name)
                            }
                        }
                    }
                }

                Section("Delivery") {
                    if let finished = status.lastSyncFinished {
                        LabeledContent("Last sync") {
                            Text(finished, style: .relative)
                        }
                    }
                    if let summary = status.lastSyncSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(services.settings.destinations.filter(\.enabled)) { destination in
                        let state = status.destinationStatus[destination.id] ?? DestinationStatus()
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(destination.name)
                                Spacer()
                                Text("\(state.pending) queued").foregroundStyle(state.pending > 0 ? .orange : .secondary)
                            }
                            if let retry = state.nextRetry, retry > Date() {
                                HStack(spacing: 4) {
                                    Text("retry")
                                    Text(retry, style: .relative)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            if let response = state.lastResponse {
                                Text(response).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("Activity Log") {
                        LogView(services: services)
                    }
                }
            }
            .navigationTitle("Pulso")
            .refreshable {
                await services.syncNow(.manual)
            }
        }
    }

    private var enabledKeys: [String] {
        (TypeRegistry.snapshots.map(\.key) + TypeRegistry.all.map(\.key)).filter { services.settings.isEnabled($0) }
    }

    private var typesWithData: [String] {
        enabledKeys.filter { (status.typeStatus[$0]?.totalDelivered ?? 0) > 0 }
    }

    private struct Row: Identifiable {
        let key: String
        let name: String
        var id: String { key }
    }

    private func rowsWithData(in group: String) -> [Row] {
        let rows = TypeRegistry.snapshots.filter { $0.group == group }.map { Row(key: $0.key, name: $0.displayName) }
            + TypeRegistry.all.filter { $0.group == group }.map { Row(key: $0.key, name: $0.displayName) }
        return rows.filter { services.settings.isEnabled($0.key) && (status.typeStatus[$0.key]?.totalDelivered ?? 0) > 0 }
    }

    @ViewBuilder
    private func typeRow(key: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            if let ts = status.typeStatus[key] {
                HStack(spacing: 4) {
                    Text("\(ts.totalDelivered) delivered")
                    if let checked = ts.lastChecked {
                        Text("· checked")
                        Text(checked, style: .relative)
                        Text("ago")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
