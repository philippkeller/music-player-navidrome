import Foundation
import Observation

/// One timed lyrics line. Lines starting with "♪" are song titles that yt.sh inserts
/// at each song start of a continuous album file.
struct LyricLine: Codable, Hashable, Sendable {
    let start: Double
    let text: String

    var isHeader: Bool { text.hasPrefix("\u{266A}") }
    var headerTitle: String { String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
}

/// Synced lyrics from Navidrome (`getLyricsBySongId`), cached on disk so they work offline.
@MainActor
@Observable
final class LyricsStore {
    @ObservationIgnored var client: SubsonicClient?
    /// Empty array = the song has no synced lyrics.
    private(set) var cache: [String: [LyricLine]] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(for songId: String) -> URL {
        directory.appendingPathComponent(songId.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    func lines(for songId: String) -> [LyricLine]? { cache[songId] }

    /// Loads lyrics once per song and launch: disk first, then the server (which may have new .lrc files).
    func load(songId: String) async {
        guard cache[songId] == nil, !loading.contains(songId) else { return }
        loading.insert(songId)
        defer { loading.remove(songId) }
        let file = Self.file(for: songId)
        if let data = try? Data(contentsOf: file), let lines = try? JSONDecoder().decode([LyricLine].self, from: data) {
            cache[songId] = lines
        }
        guard let client else { return }
        do {
            let lines = try await client.getLyrics(songId: songId) ?? []
            cache[songId] = lines
            if lines.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else if let data = try? JSONEncoder().encode(lines) {
                try? data.write(to: file, options: .atomic)
            }
        } catch {
            // Offline or the server has no lyrics API: keep what the disk had.
        }
    }

    /// Index of the line being sung at `time`.
    static func currentIndex(in lines: [LyricLine], at time: Double) -> Int? {
        lines.lastIndex { $0.start <= time + 0.3 }
    }

    /// Song title (from a "♪" line) playing at `time` in a continuous album file.
    func currentSection(songId: String?, at time: Double) -> String? {
        guard let songId, let lines = cache[songId] else { return nil }
        return lines.last { $0.isHeader && $0.start <= time + 0.3 }?.headerTitle
    }
}
