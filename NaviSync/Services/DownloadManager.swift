import Foundation
import Observation

struct DownloadedSong: Codable, Identifiable, Sendable {
    let song: Song
    let fileName: String
    let fileSize: Int64
    let date: Date
    var id: String { song.id }
}

struct DownloadGroup: Identifiable {
    let artist: String
    let songs: [Song]
    var id: String { artist }
}

/// Downloads original song files for offline playback.
@MainActor
@Observable
final class DownloadManager {
    enum State { case notDownloaded, queued, downloading, downloaded }

    private(set) var items: [String: DownloadedSong] = [:]
    private(set) var active: Set<String> = []
    private(set) var pending: [Song] = []
    private(set) var lastError: String?

    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored private let maxConcurrent = 3

    static let directory: URL = {
        var url = DiskStore.directory("Downloads")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    private static var indexURL: URL { DiskStore.baseDirectory.appendingPathComponent("downloads.json") }

    init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([DownloadedSong].self, from: data) {
            // Drop entries whose file went missing.
            let existing = list.filter { FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent($0.fileName).path) }
            items = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: Queries

    func state(for songId: String) -> State {
        if items[songId] != nil { return .downloaded }
        if active.contains(songId) { return .downloading }
        if pending.contains(where: { $0.id == songId }) { return .queued }
        return .notDownloaded
    }

    func isDownloaded(_ songs: [Song]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { items[$0.id] != nil }
    }

    func localURL(for songId: String) -> URL? {
        guard let item = items[songId] else { return nil }
        return Self.directory.appendingPathComponent(item.fileName)
    }

    var totalBytes: Int64 { items.values.reduce(0) { $0 + $1.fileSize } }

    var remainingCount: Int { active.count + pending.count }

    var groups: [DownloadGroup] {
        Dictionary(grouping: items.values.map(\.song), by: { $0.artist ?? "Unknown Artist" })
            .map { artist, songs in
                DownloadGroup(artist: artist, songs: songs.sorted {
                    ($0.album ?? "", $0.discNumber ?? 1, $0.track ?? 0) < ($1.album ?? "", $1.discNumber ?? 1, $1.track ?? 0)
                })
            }
            .sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
    }

    // MARK: Actions

    func download(_ songs: [Song]) {
        for song in songs where state(for: song.id) == .notDownloaded {
            pending.append(song)
        }
        pump()
    }

    func cancelPending() {
        pending.removeAll()
    }

    func remove(_ songIds: [String]) {
        for id in songIds {
            guard let item = items.removeValue(forKey: id) else { continue }
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(item.fileName))
        }
        saveIndex()
    }

    func removeAll() {
        pending.removeAll()
        remove(Array(items.keys))
    }

    private func pump() {
        while active.count < maxConcurrent, !pending.isEmpty {
            let song = pending.removeFirst()
            active.insert(song.id)
            Task { await perform(song) }
        }
    }

    private func perform(_ song: Song) async {
        defer {
            active.remove(song.id)
            pump()
        }
        guard let client else { return }
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: client.downloadURL(id: song.id))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SubsonicError.http(http.statusCode)
            }
            // Subsonic reports errors as JSON with status 200.
            if let mime = response.mimeType, mime.contains("json") || mime.contains("xml") {
                throw SubsonicError.unexpectedContent
            }
            let ext = song.suffix ?? response.suggestedFilename.map { ($0 as NSString).pathExtension } ?? "mp3"
            let fileName = "\(DiskStore.safeName(song.id)).\(ext.isEmpty ? "mp3" : ext)"
            let destination = Self.directory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            items[song.id] = DownloadedSong(song: song, fileName: fileName, fileSize: size, date: Date())
            saveIndex()
            _ = await CoverArtCache.shared.image(for: song.coverArt)
        } catch {
            lastError = "\(song.title): \(error.localizedDescription)"
        }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(Array(items.values)) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}
