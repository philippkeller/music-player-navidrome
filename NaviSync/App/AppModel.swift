import Observation
import SwiftUI

/// Root state: server connection plus the player, library, downloads and sync services.
@MainActor
@Observable
final class AppModel {
    private(set) var config: ServerConfig?
    var showNowPlaying = false
    /// Bumped by `refreshAll()` so artwork and open artist pages reload.
    private(set) var refreshGeneration = 0
    private(set) var isRefreshing = false

    let player: PlayerController
    let library: LibraryStore
    let downloads: DownloadManager
    let sync: SyncService

    @ObservationIgnored private(set) var client: SubsonicClient?

    init() {
        let player = PlayerController()
        self.player = player
        library = LibraryStore()
        downloads = DownloadManager()
        sync = SyncService(player: player)

        player.urlProvider = { [weak self] song in self?.playbackURL(for: song) }
        player.sonosTrackProvider = { [weak self] song in self?.client?.sonosTrack(for: song) }
        player.onEvent = { [weak self] event in self?.sync.handle(event) }
        player.onScrobble = { [weak self] song, submission in
            guard let client = self?.client else { return }
            Task { try? await client.scrobble(id: song.id, submission: submission) }
        }

        if let saved = Keychain.loadConfig() {
            apply(saved)
            sync.restoreLocal()
            player.reconnectSonos()
        }
    }

    private func apply(_ config: ServerConfig) {
        self.config = config
        let client = SubsonicClient(config: config, clientName: sync.clientName)
        self.client = client
        library.client = client
        downloads.client = client
        sync.client = client
        CoverArtCache.shared.client = client
    }

    func login(server: String, username: String, password: String) async throws {
        let config = try SubsonicClient.makeConfig(server: server, username: username, password: password)
        try await SubsonicClient(config: config, clientName: sync.clientName).ping()
        Keychain.saveConfig(config)
        apply(config)
        await sync.checkRemote()
    }

    func logout() {
        player.clear()
        sync.reset()
        library.reset()
        Keychain.deleteConfig()
        config = nil
        client = nil
        library.client = nil
        downloads.client = nil
        sync.client = nil
        CoverArtCache.shared.client = nil
    }

    /// Re-fetch artists, artist pages and artwork from the server, and sync playback.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        CoverArtCache.shared.clearDisk()
        refreshGeneration += 1
        async let artists: Void = library.refreshArtists()
        async let save: Void = sync.saveNow()
        _ = await (artists, save)
    }

    func playbackURL(for song: Song) -> URL? {
        downloads.localURL(for: song.id) ?? client?.streamURL(id: song.id)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            player.sonosAppBecameActive()
            Task { await sync.checkRemote() }
        case .background:
            Task { await sync.saveNow() }
        default:
            break
        }
    }
}
