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
/// - The same state is also kept on disk, so the app always reopens where it left off,
///   even offline or after iOS terminated it.
/// - When the app becomes active it fetches the server queue. If nothing is loaded
///   locally, the remote state is loaded (paused). If another device saved something
///   newer, a "Continue from …" banner is offered.
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

    /// What the server had at the last check, shown in Settings.
    struct RemoteSummary {
        let songTitle: String
        let position: Double
        let deviceName: String
        let changed: Date?
    }

    /// Queue and position as stored on this device.
    private struct LocalState: Codable {
        let songs: [Song]
        let index: Int
        let position: Double
        let savedAt: Date
    }

    private(set) var pendingHandoff: Handoff?
    private(set) var lastSaved: Date?
    private(set) var lastError: String?
    private(set) var lastChecked: Date?
    private(set) var lastRemote: RemoteSummary?

    let clientName: String

    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isChecking = false
    /// Set by local playback changes. Without it, merely backgrounding an idle app would
    /// upload its old queue and overwrite what another device is playing.
    @ObservationIgnored private var hasUnsavedChanges = false

    /// `changed` timestamp of the last remote queue we've dealt with, so we don't prompt twice.
    private var lastSeenChanged: String? {
        get { UserDefaults.standard.string(forKey: "sync.lastSeenChanged") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastSeenChanged") }
    }

    private static let clientPrefix = "NaviSync-"
    private static let maxQueueLength = 500
    private static var localStateURL: URL { DiskStore.baseDirectory.appendingPathComponent("playback.json") }

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
        hasUnsavedChanges = true
        saveLocal()
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
        guard hasUnsavedChanges, let client, let index = player.currentIndex, !player.queue.isEmpty else { return }
        saveLocal()
        #if os(iOS)
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SavePlayQueue", expirationHandler: nil)
        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
        #endif

        let ids = Self.window(player.queue, around: index).map(\.id)
        let queue = player.queue
        let positionMs = Int(player.currentTime * 1000)
        do {
            hasUnsavedChanges = false
            try await client.savePlayQueue(ids: ids, current: queue[index].id, positionMs: positionMs)
            lastSaved = Date()
            lastError = nil
        } catch {
            hasUnsavedChanges = true
            lastError = error.localizedDescription
        }
    }

    /// Keeps long queues bounded: a window around the current song.
    private static func window(_ queue: [Song], around index: Int) -> ArraySlice<Song> {
        let start = max(0, min(index - 50, queue.count - maxQueueLength))
        let end = min(queue.count, start + maxQueueLength)
        return queue[start..<end]
    }

    // MARK: Local state

    private func saveLocal() {
        guard let index = player.currentIndex, player.queue.indices.contains(index) else { return }
        let window = Self.window(player.queue, around: index)
        let state = LocalState(
            songs: Array(window),
            index: index - window.startIndex,
            position: player.currentTime,
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.localStateURL, options: .atomic)
    }

    /// Loads the last local queue (paused). Called once at launch.
    func restoreLocal() {
        guard player.queue.isEmpty,
              let data = try? Data(contentsOf: Self.localStateURL),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else { return }
        player.load(state.songs, index: state.index, position: state.position, autoplay: false)
    }

    private var localSavedAt: Date? {
        guard let data = try? Data(contentsOf: Self.localStateURL),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else { return nil }
        return state.savedAt
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
            lastChecked = Date()
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard let remote, let entries = remote.entry, !entries.isEmpty else {
            lastRemote = nil
            return
        }
        let index = entries.firstIndex { $0.id == remote.current } ?? 0
        let position = Double(remote.position ?? 0) / 1000
        let remoteDate = Self.parseDate(remote.changed)
        lastRemote = RemoteSummary(
            songTitle: entries[index].title,
            position: position,
            deviceName: Self.deviceName(from: remote.changedBy),
            changed: remoteDate
        )

        // Fresh start: restore whatever was playing last, from any device.
        if player.queue.isEmpty {
            player.load(entries, index: index, position: position, autoplay: false)
            lastSeenChanged = remote.changed
            return
        }

        if remote.changedBy == clientName || (remote.changed != nil && remote.changed == lastSeenChanged) {
            return
        }

        // Our own local state is newer (e.g. our last upload failed): keep it.
        if let remoteDate, let local = localSavedAt, local > remoteDate {
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
        saveLocal()
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
        lastChecked = nil
        lastRemote = nil
        try? FileManager.default.removeItem(at: Self.localStateURL)
    }

    /// Navidrome sends RFC 3339 dates with up to nanosecond precision, which
    /// ISO8601DateFormatter can't parse, so the fraction is dropped.
    static func parseDate(_ string: String?) -> Date? {
        guard var string else { return nil }
        if let dot = string.firstIndex(of: "."),
           let end = string[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            string.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: string)
    }

    static func deviceName(from client: String?) -> String {
        guard let client, !client.isEmpty else { return "another device" }
        if client.hasPrefix(clientPrefix) { return String(client.dropFirst(clientPrefix.count)) }
        return client
    }
}
