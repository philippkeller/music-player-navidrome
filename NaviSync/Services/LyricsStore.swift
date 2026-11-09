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

private let lyricsOffsetsKey = "lyricsOffsets"

/// Synced lyrics from Navidrome (`getLyricsBySongId`), cached on disk so they work offline.
@MainActor
@Observable
final class LyricsStore {
    @ObservationIgnored var client: SubsonicClient?
    /// Empty array = the song has no synced lyrics.
    private(set) var cache: [String: [LyricLine]] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    /// Timing fixes made by tapping a line: song id → section (index of its "♪" line, 0 without one) → seconds.
    private var offsets: [String: [String: Double]] =
        UserDefaults.standard.dictionary(forKey: lyricsOffsetsKey) as? [String: [String: Double]] ?? [:]

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(for songId: String) -> URL {
        directory.appendingPathComponent(songId.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    /// Lyrics with the user's timing fixes applied. Song-title lines stay put: those times come from the files.
    func lines(for songId: String) -> [LyricLine]? {
        guard let raw = cache[songId] else { return nil }
        guard let shifts = offsets[songId], !shifts.isEmpty else { return raw }
        var section = 0
        return raw.enumerated().map { index, line in
            if line.isHeader { section = index; return line }
            return LyricLine(start: line.start + (shifts[String(section)] ?? 0), text: line.text)
        }
    }

    /// "This line is being sung now": shifts the timing of the line's song so the line starts at `time`.
    func sync(songId: String, lineIndex: Int, to time: Double) {
        guard let raw = cache[songId], raw.indices.contains(lineIndex), !raw[lineIndex].isHeader else { return }
        offsets[songId, default: [:]][String(section(of: lineIndex, in: raw))] = time - raw[lineIndex].start
        saveOffsets()
    }

    func resetTiming(songId: String, lineIndex: Int) {
        guard let raw = cache[songId] else { return }
        offsets[songId]?[String(section(of: lineIndex, in: raw))] = nil
        if offsets[songId]?.isEmpty == true { offsets[songId] = nil }
        saveOffsets()
    }

    func hasTimingFix(songId: String, lineIndex: Int) -> Bool {
        guard let raw = cache[songId] else { return false }
        return offsets[songId]?[String(section(of: lineIndex, in: raw))] != nil
    }

    private func section(of lineIndex: Int, in lines: [LyricLine]) -> Int {
        lines[...min(lineIndex, lines.count - 1)].lastIndex(where: \.isHeader) ?? 0
    }

    private func saveOffsets() {
        UserDefaults.standard.set(offsets, forKey: lyricsOffsetsKey)
    }

    /// Loads lyrics once per song and launch: disk first, then the server (which may have new .lrc files).
    /// "No lyrics" is asked again each time, since an .lrc may have been added since.
    func load(songId: String) async {
        guard cache[songId]?.isEmpty ?? true, !loading.contains(songId) else { return }
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
