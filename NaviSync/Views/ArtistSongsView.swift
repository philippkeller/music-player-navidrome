import SwiftUI

struct ArtistSongsView: View {
    let artist: Artist

    @Environment(AppModel.self) private var model
    @State private var content: ArtistSongs?
    @State private var error: String?
    @State private var isLoading = false

    private var allSongs: [Song] { content?.allSongs ?? [] }

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)

            ForEach(content?.albums ?? []) { section in
                Section {
                    ForEach(section.songs) { song in
                        Button {
                            play(song)
                        } label: {
                            SongRow(song: song)
                        }
                        .buttonStyle(.plain)
                        .songActions(song)
                    }
                } header: {
                    AlbumHeader(section: section)
                }
            }
        }
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
        .refreshable { await load() }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            CoverArtView(coverArtId: artist.coverArt, cornerRadius: 60)
                .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 10) {
                Text(artist.name).font(.title2.bold()).lineLimit(2)
                if let content {
                    Text("\(content.albums.count) albums · \(allSongs.count) songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        model.player.play(allSongs)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.player.play(allSongs.shuffled())
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)

                    DownloadButton(songs: allSongs)
                }
                .controlSize(.small)
                .disabled(allSongs.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
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

private struct AlbumHeader: View {
    let section: AlbumSection
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            CoverArtView(coverArtId: section.album.coverArt, cornerRadius: 4)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.album.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let year = section.album.year, year > 0 {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Play Album", systemImage: "play.fill") { model.player.play(section.songs) }
                Button("Play Next", systemImage: "text.insert") { model.player.playNext(section.songs) }
                Button("Add to Queue", systemImage: "text.append") { model.player.addToQueue(section.songs) }
                if model.downloads.isDownloaded(section.songs) {
                    Button("Remove Download", systemImage: "trash", role: .destructive) {
                        model.downloads.remove(section.songs.map(\.id))
                    }
                } else {
                    Button("Download Album", systemImage: "arrow.down.circle") { model.downloads.download(section.songs) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

/// Download / downloaded toggle for a set of songs.
struct DownloadButton: View {
    let songs: [Song]
    @Environment(AppModel.self) private var model

    var body: some View {
        let downloads = model.downloads
        let isDownloaded = downloads.isDownloaded(songs)
        let inProgress = songs.contains { downloads.state(for: $0.id) == .downloading || downloads.state(for: $0.id) == .queued }
        Button {
            if !isDownloaded { downloads.download(songs) }
        } label: {
            if inProgress {
                ProgressView().controlSize(.small)
            } else {
                Label(isDownloaded ? "Downloaded" : "Download",
                      systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .disabled(isDownloaded || inProgress)
    }
}
