import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let downloads = model.downloads
        let groups = downloads.groups
        List {
            if downloads.remainingCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Downloading \(downloads.remainingCount) songs…")
                        Spacer()
                        Button("Cancel") { downloads.cancelPending() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if let error = downloads.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section(group.artist) {
                    ForEach(group.songs) { song in
                        Button {
                            if let index = group.songs.firstIndex(of: song) {
                                model.player.play(group.songs, startAt: index)
                            }
                        } label: {
                            SongRow(song: song)
                        }
                        .buttonStyle(.plain)
                        .songActions(song)
                    }
                    .onDelete { offsets in
                        downloads.remove(offsets.map { group.songs[$0].id })
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty && downloads.remainingCount == 0 {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download artists, albums or songs to listen offline.")
                )
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem {
                Text(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
