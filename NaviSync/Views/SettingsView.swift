import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeleteDownloads = false

    var body: some View {
        let sync = model.sync
        let downloads = model.downloads
        Form {
            Section("Server") {
                if let config = model.config {
                    LabeledContent("Server", value: config.baseURL.absoluteString)
                    LabeledContent("User", value: config.username)
                    Button("Log Out", role: .destructive) { model.logout() }
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("This device", value: sync.clientName)
                LabeledContent("Last saved", value: sync.lastSaved?.formatted(date: .abbreviated, time: .standard) ?? "—")
                LabeledContent("Last checked", value: sync.lastChecked?.formatted(date: .abbreviated, time: .standard) ?? "—")
                if let remote = sync.lastRemote {
                    LabeledContent("On server") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(remote.songTitle) · \(formatTime(remote.position))")
                            Text("from \(remote.deviceName)\(remote.changed.map { ", " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = sync.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Check for Other Devices Now") {
                    Task { await sync.checkRemote() }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("The current queue and position are saved to your Navidrome server. Open the app on another device to continue where you left off.")
            }

            Section("Downloads") {
                LabeledContent("Songs", value: String(downloads.items.count))
                LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                Button("Delete All Downloads", role: .destructive) { confirmDeleteDownloads = true }
                    .disabled(downloads.items.isEmpty)
                Button("Clear Artwork Cache") { CoverArtCache.shared.clearDisk() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Delete all downloaded songs?", isPresented: $confirmDeleteDownloads, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { downloads.removeAll() }
        }
    }
}
