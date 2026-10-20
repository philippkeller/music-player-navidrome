import SwiftUI

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    private struct LetterSection: Identifiable {
        let letter: String
        let artists: [Artist]
        var id: String { letter }
    }

    private var sections: [LetterSection] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty
            ? model.library.artists
            : model.library.artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: filtered) { artist -> String in
            let first = artist.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).prefix(1).uppercased()
            return first.first?.isLetter == true ? first : "#"
        }
        return grouped
            .map { LetterSection(letter: $0.key, artists: $0.value) }
            .sorted { ($0.letter == "#" ? "~" : $0.letter) < ($1.letter == "#" ? "~" : $1.letter) }
    }

    var body: some View {
        let library = model.library
        List {
            ForEach(sections) { section in
                Section(section.letter) {
                    ForEach(section.artists) { artist in
                        NavigationLink(value: artist) {
                            ArtistRow(artist: artist)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.artists.isEmpty {
                if library.isLoadingArtists {
                    ProgressView()
                } else if let error = library.artistsError {
                    ContentUnavailableView("Can't Load Artists", systemImage: "wifi.exclamationmark", description: Text(error))
                }
            } else if !searchText.isEmpty && sections.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("Artists")
        .navigationDestination(for: Artist.self) { artist in
            ArtistSongsView(artist: artist)
        }
        .searchable(text: $searchText, prompt: "Search Artists")
        .refreshable { await library.refreshArtists() }
        .task { await library.refreshArtistsIfNeeded() }
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await library.refreshArtists() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        #endif
    }
}

private struct ArtistRow: View {
    let artist: Artist

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(coverArtId: artist.coverArt, cornerRadius: 22)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name).lineLimit(1)
                if let count = artist.albumCount {
                    Text(count == 1 ? "1 album" : "\(count) albums")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
