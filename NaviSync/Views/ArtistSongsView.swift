import SwiftUI

struct ArtistSongsView: View {
    let artist: Artist

    @Environment(AppModel.self) private var model
    @State private var content: ArtistSongs?
    @State private var error: String?
    @State private var isLoading = false

    private var allSongs: [Song] { content?.allSongs ?? [] }

    /// Album year by album id, shown in the song subtitle.
    private var albumYears: [String: Int] {
        Dictionary((content?.albums ?? []).compactMap { section in
            section.album.year.flatMap { $0 > 0 ? (section.album.id, $0) : nil }
        }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let years = albumYears
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))

            ForEach(allSongs) { song in
                Button {
                    play(song)
                } label: {
                    SongRow(song: song, subtitle: albumSubtitle(song, years: years))
                }
                .buttonStyle(.plain)
                .songActions(song)
            }
        }
        .listStyle(.plain)
        .overlay {
            if content == nil {
                if isLoading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView("Can't Load Songs", systemImage: "wifi.exclamationmark", description: Text(error))
                }
            }
        }
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                actionsMenu
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            CoverArtView(coverArtId: artist.coverArt, cornerRadius: 8)
                .frame(maxWidth: 240)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                .padding(.top, 8)

            VStack(spacing: 4) {
                Text(artist.name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let content {
                    Text("\(content.albums.count) Albums · \(allSongs.count) Songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Button {
                    model.player.play(allSongs)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                Button {
                    model.player.play(allSongs.shuffled())
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(allSongs.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionsMenu: some View {
        let songs = allSongs
        let downloads = model.downloads
        return Menu {
            Button("Play Next", systemImage: "text.insert") { model.player.playNext(songs) }
            Button("Add to Queue", systemImage: "text.append") { model.player.addToQueue(songs) }
            Divider()
            if downloads.isDownloaded(songs) {
                Button("Remove Downloads", systemImage: "trash", role: .destructive) {
                    downloads.remove(songs.map(\.id))
                }
            } else {
                Button("Download All", systemImage: "arrow.down.circle") { downloads.download(songs) }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .disabled(songs.isEmpty)
    }

    private func albumSubtitle(_ song: Song, years: [String: Int]) -> String {
        let year = (song.albumId.flatMap { years[$0] } ?? song.year).flatMap { $0 > 0 ? String($0) : nil }
        return [song.album, year].compactMap { $0 }.joined(separator: " · ")
    }

    private func play(_ song: Song) {
        let songs = allSongs
        guard let index = songs.firstIndex(of: song) else { return }
        model.player.play(songs, startAt: index)
    }

    private func load() async {
        if content == nil { content = model.library.cachedSongs(for: artist.id) }
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await model.library.loadSongs(for: artist.id)
            error = nil
        } catch {
            if content == nil { self.error = error.localizedDescription }
        }
    }
}
