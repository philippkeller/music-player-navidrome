import SwiftUI

struct SongRow: View {
    let song: Song
    var showArtist = false

    @Environment(AppModel.self) private var model

    var body: some View {
        let isCurrent = model.player.currentSong?.id == song.id
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.tint)
                } else {
                    Text(song.track.map { String($0) } ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if showArtist, let artist = song.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            DownloadStateIcon(songId: song.id)

            Text(formatTime(Double(song.duration ?? 0)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

struct DownloadStateIcon: View {
    let songId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.downloads.state(for: songId) {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView().controlSize(.mini)
        case .queued:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .notDownloaded:
            EmptyView()
        }
    }
}

private struct SongActions: ViewModifier {
    let song: Song
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let downloaded = model.downloads.state(for: song.id) == .downloaded
        content
            .contextMenu {
                Button("Play Next", systemImage: "text.insert") { model.player.playNext([song]) }
                Button("Add to Queue", systemImage: "text.append") { model.player.addToQueue([song]) }
                Divider()
                if downloaded {
                    Button("Remove Download", systemImage: "trash", role: .destructive) {
                        model.downloads.remove([song.id])
                    }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") { model.downloads.download([song]) }
                }
            }
            #if os(iOS)
            .swipeActions(edge: .leading) {
                Button { model.player.playNext([song]) } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing) {
                if downloaded {
                    Button(role: .destructive) { model.downloads.remove([song.id]) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } else {
                    Button { model.downloads.download([song]) } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(.blue)
                }
            }
            #endif
    }
}

extension View {
    /// Context menu (and swipe actions on iOS) for a song row.
    func songActions(_ song: Song) -> some View {
        modifier(SongActions(song: song))
    }
}
