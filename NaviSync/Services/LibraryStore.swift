import Foundation
import Observation

/// Artist list and artist pages. Everything is cached on disk so browsing works offline.
@MainActor
@Observable
final class LibraryStore {
    private(set) var artists: [Artist] = []
    private(set) var isLoadingArtists = false
    private(set) var artistsError: String?

    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored private var refreshedThisSession = false

    init() {
        artists = DiskStore.load([Artist].self, name: "artists") ?? []
    }

    func refreshArtistsIfNeeded() async {
        guard !refreshedThisSession else { return }
        await refreshArtists()
    }

    func refreshArtists() async {
        guard let client, !isLoadingArtists else { return }
        isLoadingArtists = true
        defer { isLoadingArtists = false }
        do {
            let fetched = try await client.getArtists()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            artists = fetched
            artistsError = nil
            refreshedThisSession = true
            DiskStore.save(fetched, name: "artists")
        } catch {
            artistsError = error.localizedDescription
        }
    }

    func cachedSongs(for artistId: String) -> ArtistSongs? {
        DiskStore.load(ArtistSongs.self, name: "artist-\(artistId)")
    }

    func loadSongs(for artistId: String) async throws -> ArtistSongs {
        guard let client else { throw SubsonicError.invalidURL }
        let songs = try await client.getArtistSongs(artistId: artistId)
        DiskStore.save(songs, name: "artist-\(artistId)")
        return songs
    }

    func reset() {
        artists = []
        artistsError = nil
        refreshedThisSession = false
        DiskStore.clearLibrary()
    }
}
