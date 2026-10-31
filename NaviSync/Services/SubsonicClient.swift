import CryptoKit
import Foundation

/// Credentials for a Subsonic/Navidrome server. We store the salted token, never the password.
struct ServerConfig: Codable, Equatable, Sendable {
    var baseURL: URL
    var username: String
    var salt: String
    var token: String
}

enum SubsonicError: LocalizedError {
    case invalidURL
    case http(Int)
    case server(code: Int, message: String)
    case unexpectedContent

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The server address is not valid."
        case .http(let code): "The server responded with HTTP \(code)."
        case .server(_, let message): message
        case .unexpectedContent: "The server sent an unexpected response."
        }
    }

    /// Subsonic error 70 = "data not found" (e.g. no saved play queue yet).
    var isNotFound: Bool {
        if case .server(70, _) = self { return true }
        return false
    }
}

/// Minimal client for the Subsonic API endpoints we need.
struct SubsonicClient: Sendable {
    static let apiVersion = "1.16.1"

    let config: ServerConfig
    /// Sent as `c` parameter. Navidrome stores it as `changedBy` on the play queue,
    /// which is how we tell which device saved it.
    let clientName: String

    static func makeConfig(server: String, username: String, password: String) throws -> ServerConfig {
        var address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "https://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        guard let url = URL(string: address), url.host != nil else { throw SubsonicError.invalidURL }
        let salt = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return ServerConfig(baseURL: url, username: username, salt: salt, token: md5(password + salt))
    }

    private static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: URLs

    private var authItems: [URLQueryItem] {
        [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: config.token),
            URLQueryItem(name: "s", value: config.salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    func url(_ endpoint: String, _ params: [URLQueryItem] = []) -> URL {
        let endpointURL = config.baseURL.appendingPathComponent("rest").appendingPathComponent(endpoint)
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        components.queryItems = authItems + params
        return components.url!
    }

    /// `format=raw` asks for the original file: transcoded streams can't be seeked with
    /// byte ranges, so jumping ahead in them hangs.
    func streamURL(id: String) -> URL {
        url("stream", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "format", value: "raw")])
    }

    /// Original file, used for offline downloads.
    func downloadURL(id: String) -> URL { url("download", [URLQueryItem(name: "id", value: id)]) }

    func coverArtURL(id: String, size: Int = 600) -> URL {
        url("getCoverArt", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "size", value: String(size))])
    }

    // MARK: Requests

    private func get<T: Decodable>(_ endpoint: String, _ params: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url(endpoint, params))
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubsonicError.http(http.statusCode)
        }
        let decoder = JSONDecoder()
        let status = try decoder.decode(Envelope<StatusPayload>.self, from: data).response
        guard status.status == "ok" else {
            throw SubsonicError.server(code: status.error?.code ?? 0, message: status.error?.message ?? "Unknown server error")
        }
        return try decoder.decode(Envelope<T>.self, from: data).response
    }

    func ping() async throws {
        _ = try await get("ping", as: StatusPayload.self)
    }

    func getArtists() async throws -> [Artist] {
        let payload = try await get("getArtists", as: ArtistsPayload.self)
        return (payload.artists?.index ?? []).flatMap { $0.artist ?? [] }
    }

    /// All songs of an artist, grouped by album (newest album first).
    func getArtistSongs(artistId: String) async throws -> ArtistSongs {
        let payload = try await get("getArtist", [URLQueryItem(name: "id", value: artistId)], as: ArtistPayload.self)
        let albums = payload.artist?.album ?? []
        let sections = try await withThrowingTaskGroup(of: AlbumSection.self) { group in
            for album in albums {
                group.addTask {
                    let albumPayload = try await get("getAlbum", [URLQueryItem(name: "id", value: album.id)], as: AlbumPayload.self)
                    let songs = (albumPayload.album?.song ?? []).sorted(by: Song.trackOrder)
                    return AlbumSection(album: album, songs: songs)
                }
            }
            var result: [AlbumSection] = []
            for try await section in group { result.append(section) }
            return result
        }
        let sorted = sections.sorted {
            let (y0, y1) = ($0.album.year ?? 0, $1.album.year ?? 0)
            return y0 != y1 ? y0 > y1 : $0.album.name.localizedCaseInsensitiveCompare($1.album.name) == .orderedAscending
        }
        return ArtistSongs(albums: sorted)
    }

    func getPlayQueue() async throws -> RemotePlayQueue? {
        do {
            return try await get("getPlayQueue", as: PlayQueuePayload.self).playQueue
        } catch let error as SubsonicError where error.isNotFound {
            return nil
        }
    }

    /// Saves queue, current song and position (ms) on the server. Sent as POST form
    /// because queues can get long.
    func savePlayQueue(ids: [String], current: String?, positionMs: Int) async throws {
        var items = authItems + ids.map { URLQueryItem(name: "id", value: $0) }
        if let current {
            items.append(URLQueryItem(name: "current", value: current))
            items.append(URLQueryItem(name: "position", value: String(positionMs)))
        }
        var components = URLComponents()
        components.queryItems = items
        var request = URLRequest(url: config.baseURL.appendingPathComponent("rest").appendingPathComponent("savePlayQueue"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let _: StatusPayload = try decode(data, response)
    }

    func scrobble(id: String, submission: Bool) async throws {
        _ = try await get("scrobble", [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "submission", value: submission ? "true" : "false"),
        ], as: StatusPayload.self)
    }
}

// MARK: - Response payloads

private struct Envelope<T: Decodable>: Decodable {
    let response: T
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

private struct StatusPayload: Decodable {
    struct APIError: Decodable {
        let code: Int
        let message: String?
    }
    let status: String
    let error: APIError?
}

private struct ArtistsPayload: Decodable {
    struct Index: Decodable {
        let name: String
        let artist: [Artist]?
    }
    struct Artists: Decodable { let index: [Index]? }
    let artists: Artists?
}

private struct ArtistPayload: Decodable {
    struct ArtistWithAlbums: Decodable {
        let id: String
        let name: String
        let album: [Album]?
    }
    let artist: ArtistWithAlbums?
}

private struct AlbumPayload: Decodable {
    struct AlbumWithSongs: Decodable { let song: [Song]? }
    let album: AlbumWithSongs?
}

private struct PlayQueuePayload: Decodable {
    let playQueue: RemotePlayQueue?
}
