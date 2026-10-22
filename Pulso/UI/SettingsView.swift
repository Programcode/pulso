import SwiftUI

struct SettingsView: View {
    let services: AppServices

    @State private var confirmReimport = false

    var body: some View {
        NavigationStack {
            Form {
                DestinationsSection(services: services)

                Section {
                    ForEach(TypeRegistry.perObjectTypes, id: \.key) { entry in
                        Button("Choose \(entry.displayName) to share") {
                            Task { await services.requestPerObjectAccess(entry.key) }
                        }
                    }
                    NavigationLink("Coverage: what is synced and what isn't") {
                        CoverageView()
                    }
                } header: {
                    Text("Health Access")
                } footer: {
                    Text("HealthKit shares these item by item from its own picker, so they need a tap here rather than the main permission sheet.")
                }

                ForEach(TypeRegistry.groups, id: \.self) { group in
                    let keys = TypeRegistry.all.filter { $0.group == group }.map(\.key)
                        + TypeRegistry.snapshots.filter { $0.group == group }.map(\.key)
                    Section {
                        ForEach(TypeRegistry.snapshots.filter { $0.group == group }) { source in
                            Toggle(source.displayName, isOn: enabledBinding(source.key))
                        }
                        ForEach(TypeRegistry.all.filter { $0.group == group }) { type in
                            Toggle(type.displayName, isOn: enabledBinding(type.key))
                        }
                    } header: {
                        HStack {
                            Text(group)
                            Spacer()
                            Button("All") { setAll(keys, true) }
                            Text("·")
                            Button("None") { setAll(keys, false) }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    } footer: {
                        if group == TypeRegistry.groups.last {
                            Text("Disabling a type stops new deliveries; data already on your server stays there. Newly enabled types back-fill their full history on the next sync.")
                        }
                    }
                }

                Section {
                    Button("Re-import Full History", role: .destructive) {
                        confirmReimport = true
                    }
                    .confirmationDialog("Re-import everything?", isPresented: $confirmReimport) {
                        Button("Re-import", role: .destructive) {
                            Task { await services.reimportAll() }
                        }
                    } message: {
                        Text("Clears local sync state and sends your entire history again. Your server deduplicates by sample ID, so this is safe — just slow.")
                    }
                } header: {
                    Text("Maintenance")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Pulso reads the Apple Health data you select and delivers it to the destinations you configure. No cloud, no accounts, no analytics.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func enabledBinding(_ key: String) -> Binding<Bool> {
        Binding {
            services.settings.isEnabled(key)
        } set: { value in
            services.settings.setEnabled(key, value)
            services.typeTogglesChanged()
        }
    }

    private func setAll(_ keys: [String], _ value: Bool) {
        for key in keys {
            services.settings.setEnabled(key, value)
        }
        services.typeTogglesChanged()
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Every identifier in the SDK this build was compiled with, split into
/// what syncs and what doesn't (with the reason).
struct CoverageView: View {
    var body: some View {
        let refused = HealthAuthorization.lastRejected()
        List {
            Section {
                LabeledContent("SDK", value: "iOS \(HealthKitCatalog.sdkVersion)")
                LabeledContent("Sample types", value: "\(TypeRegistry.all.count)")
                LabeledContent("Snapshot sources", value: "\(TypeRegistry.snapshots.count)")
            }
            if !refused.isEmpty {
                Section("Refused by this iOS") {
                    ForEach(refused.sorted(), id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            Section("Not synced") {
                ForEach(TypeRegistry.skipped, id: \.identifier) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.identifier).font(.caption.monospaced())
                        Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("Clinical records (FHIR) are not requested: they need the health-records entitlement, which re-signing certificates generally don't carry.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Synced") {
                ForEach(TypeRegistry.snapshots) { Text($0.key).font(.caption.monospaced()) }
                ForEach(TypeRegistry.all) { Text($0.key).font(.caption.monospaced()) }
            }
        }
        .navigationTitle("Coverage")
    }
}
