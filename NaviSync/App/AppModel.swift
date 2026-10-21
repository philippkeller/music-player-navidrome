import Observation
import SwiftUI

/// Root state: server connection plus the player, library, downloads and sync services.
@MainActor
@Observable
final class AppModel {
    private(set) var config: ServerConfig?
    var showNowPlaying = false

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
        player.onEvent = { [weak self] event in self?.sync.handle(event) }
        player.onScrobble = { [weak self] song, submission in
            guard let client = self?.client else { return }
            Task { try? await client.scrobble(id: song.id, submission: submission) }
        }

        if let saved = Keychain.loadConfig() {
            apply(saved)
            sync.restoreLocal()
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

    func playbackURL(for song: Song) -> URL? {
        downloads.localURL(for: song.id) ?? client?.streamURL(id: song.id)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await sync.checkRemote() }
        case .background:
            Task { await sync.saveNow() }
        default:
            break
        }
    }
}
