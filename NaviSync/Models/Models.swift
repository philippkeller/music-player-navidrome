import Foundation

struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var albumCount: Int?
    var coverArt: String?
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var artist: String?
    var artistId: String?
    var year: Int?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
}

struct Song: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var album: String?
    var albumId: String?
    var artist: String?
    var artistId: String?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Int?
    var coverArt: String?
    var suffix: String?
    var size: Int?

    /// Album order: disc, then track number, then title.
    static func trackOrder(_ a: Song, _ b: Song) -> Bool {
        (a.discNumber ?? 1, a.track ?? 0, a.title) < (b.discNumber ?? 1, b.track ?? 0, b.title)
    }
}

/// One album of an artist together with its songs.
struct AlbumSection: Codable, Identifiable, Hashable, Sendable {
    let album: Album
    let songs: [Song]
    var id: String { album.id }
}

/// Everything shown on an artist page.
struct ArtistSongs: Codable, Sendable {
    let albums: [AlbumSection]
    var allSongs: [Song] { albums.flatMap(\.songs) }
}

/// The play queue as stored on the server (Subsonic `getPlayQueue`).
struct RemotePlayQueue: Decodable, Sendable {
    var entry: [Song]?
    var current: String?
    /// Position in milliseconds within the current song.
    var position: Int?
    var changed: String?
    var changedBy: String?
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
