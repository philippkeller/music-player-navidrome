import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Hands playback over between devices via Navidrome's saved play queue
/// (`savePlayQueue` / `getPlayQueue`).
///
/// - While playing, the queue + position is saved every ~10 s and on pause, seek,
///   track change and when the app goes to the background.
/// - When the app becomes active it fetches the server queue. If nothing is loaded
///   locally, the remote state is loaded (paused). If another device saved something
///   different, a "Continue from …" banner is offered.
@MainActor
@Observable
final class SyncService {
    struct Handoff: Identifiable {
        let id = UUID()
        let deviceName: String
        let songs: [Song]
        let index: Int
        let position: Double
        let changed: String?
        var song: Song { songs[index] }
    }

    private(set) var pendingHandoff: Handoff?
    private(set) var lastSaved: Date?
    private(set) var lastError: String?

    let clientName: String

    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isChecking = false

    /// `changed` timestamp of the last remote queue we've dealt with, so we don't prompt twice.
    private var lastSeenChanged: String? {
        get { UserDefaults.standard.string(forKey: "sync.lastSeenChanged") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastSeenChanged") }
    }

    private static let clientPrefix = "NaviSync-"
    private static let maxQueueLength = 500

    init(player: PlayerController) {
        self.player = player
        #if os(iOS)
        clientName = Self.clientPrefix + UIDevice.current.model // "iPhone" / "iPad"
        #else
        clientName = Self.clientPrefix + "Mac"
        #endif
    }

    // MARK: Saving

    func handle(_ event: PlayerEvent) {
        switch event {
        case .tick, .paused, .seeked:
            scheduleSave(delay: 0)
        case .trackChanged, .queueChanged, .started:
            // A local choice overrides whatever another device offered.
            if let handoff = pendingHandoff {
                lastSeenChanged = handoff.changed
                pendingHandoff = nil
            }
            // Short debounce so skipping through tracks doesn't spam the server.
            scheduleSave(delay: 1.5)
        }
    }

    private func scheduleSave(delay: Double) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        guard let client, let index = player.currentIndex, !player.queue.isEmpty else { return }
        #if os(iOS)
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SavePlayQueue", expirationHandler: nil)
        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
        #endif

        // Keep long queues bounded: a window around the current song.
        let queue = player.queue
        let start = max(0, min(index - 50, queue.count - Self.maxQueueLength))
        let end = min(queue.count, start + Self.maxQueueLength)
        let ids = queue[start..<end].map(\.id)
        let positionMs = Int(player.currentTime * 1000)
        do {
            try await client.savePlayQueue(ids: ids, current: queue[index].id, positionMs: positionMs)
            lastSaved = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Checking

    func checkRemote() async {
        guard let client, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let remote: RemotePlayQueue?
        do {
            remote = try await client.getPlayQueue()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard let remote, let entries = remote.entry, !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == remote.current } ?? 0
        let position = Double(remote.position ?? 0) / 1000

        // Fresh start: restore whatever was playing last, from any device.
        if player.queue.isEmpty {
            player.load(entries, index: index, position: position, autoplay: false)
            lastSeenChanged = remote.changed
            return
        }

        if remote.changedBy == clientName || (remote.changed != nil && remote.changed == lastSeenChanged) {
            return
        }

        let sameTrack = player.currentSong?.id == entries[index].id
        if sameTrack, abs(player.currentTime - position) < 5 {
            lastSeenChanged = remote.changed
            return
        }

        pendingHandoff = Handoff(
            deviceName: Self.deviceName(from: remote.changedBy),
            songs: entries,
            index: index,
            position: position,
            changed: remote.changed
        )
    }

    func acceptHandoff() {
        guard let handoff = pendingHandoff else { return }
        lastSeenChanged = handoff.changed
        pendingHandoff = nil
        player.load(handoff.songs, index: handoff.index, position: handoff.position, autoplay: true)
    }

    func dismissHandoff() {
        lastSeenChanged = pendingHandoff?.changed
        pendingHandoff = nil
    }

    func reset() {
        saveTask?.cancel()
        pendingHandoff = nil
        lastSaved = nil
        lastError = nil
        lastSeenChanged = nil
    }

    static func deviceName(from client: String?) -> String {
        guard let client, !client.isEmpty else { return "another device" }
        if client.hasPrefix(clientPrefix) { return String(client.dropFirst(clientPrefix.count)) }
        return client
    }
}
