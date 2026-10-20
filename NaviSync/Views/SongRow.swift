import SwiftUI

/// Song row with album artwork, title and a subtitle (album or artist).
struct SongRow: View {
    let song: Song
    /// Defaults to "Album · Artist" when nil.
    var subtitle: String?

    @Environment(AppModel.self) private var model

    var body: some View {
        let isCurrent = model.player.currentSong?.id == song.id
        HStack(spacing: 12) {
            CoverArtView(coverArtId: song.coverArt, cornerRadius: 4)
                .frame(width: 48, height: 48)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                        Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                let detail = subtitle ?? [song.album, song.artist].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            DownloadStateIcon(songId: song.id)

            Text(formatTime(Double(song.duration ?? 0)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
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
