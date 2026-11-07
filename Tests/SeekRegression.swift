import AppKit
import AVFoundation
import Foundation

// Artwork is unrelated to seeking; keep this standalone runner independent of disk caches.
typealias PlatformImage = NSImage
@MainActor
final class CoverArtCache {
    static let shared = CoverArtCache()
    func image(for id: String?) async -> NSImage? { nil }
}

@main
struct SeekRegression {
    @MainActor
    static func main() {
        // Use an injected monotonic time to cover hangs without sleeping or contacting a server.
        var stalled = PlaybackProgressWatchdog(now: 0, position: 0)
        precondition(!stalled.check(now: 7, position: 0, active: true, positioned: true))
        precondition(stalled.check(now: 8, position: 0, active: true, positioned: true))
        var loading = PlaybackProgressWatchdog(now: 0, position: 0)
        precondition(loading.check(now: 8, position: 120, active: true, positioned: false))
        var backwards = PlaybackProgressWatchdog(now: 0, position: 200)
        precondition(!backwards.check(now: 1, position: 40, active: true, positioned: true))
        precondition(!backwards.check(now: 8, position: 47, active: true, positioned: true))
        precondition(backwards.check(now: 16, position: 47, active: true, positioned: true))
        var healthy = PlaybackProgressWatchdog(now: 0, position: 0)
        for second in 1...10 {
            precondition(!healthy.check(now: Double(second), position: Double(second),
                                       active: true, positioned: true))
        }
        precondition(healthy.advancedSeconds >= 5)
        precondition(!healthy.check(now: 11, position: 10, active: true, positioned: true))
        precondition(healthy.advancedSeconds == 0)
        precondition(healthy.check(now: 18, position: 10, active: true, positioned: true))
        precondition(!healthy.check(now: 100, position: 10, active: false, positioned: true))
        precondition(!healthy.check(now: 101, position: 10, active: true, positioned: true))
        precondition(healthy.check(now: 108, position: .nan, active: true, positioned: true))

        let client = SubsonicClient(config: ServerConfig(
            baseURL: URL(string: "https://example.invalid/music")!,
            username: "test", salt: "test", token: "test"
        ), clientName: "SeekRegression")
        let mp3 = Song(id: "one", title: "One", duration: 300, suffix: "mp3")
        let flac = Song(id: "two", title: "Two", duration: 240, suffix: "flac")
        func query(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") })
        }
        // Request a different codec, otherwise Navidrome can return raw audio and ignore the offset.
        for song in [mp3, flac] {
            let values = query(client.streamURL(for: song, startingAt: 123.9))
            precondition(values["timeOffset"] == "123")
            precondition(values["format"] != song.suffix)
            precondition(values["format"] != "raw")
            precondition(values["id"] == song.id)
        }
        let player = PlayerController()
        precondition(!player.avPlayer.automaticallyWaitsToMinimizeStalling)
        player.urlProvider = { client.streamURL(id: $0.id) }
        player.offsetStreamURLProvider = { client.streamURL(for: $0, startingAt: $1) }
        func currentQuery() -> [String: String] {
            query((player.avPlayer.currentItem!.asset as! AVURLAsset).url)
        }
        player.play([mp3, flac])
        precondition(currentQuery()["format"] == "raw")
        player.seek(to: 120)
        precondition(currentQuery()["timeOffset"] == "120")
        precondition(player.currentTime == 120 && player.duration == 300)
        precondition(player.isPlaying && player.isBuffering)
        // A second seek must replace the first request without waiting for it to complete.
        let previousItem = player.avPlayer.currentItem
        player.seek(to: 200)
        precondition(player.avPlayer.currentItem !== previousItem)
        precondition(currentQuery()["timeOffset"] == "200")
        player.pause()
        player.seek(to: 40)
        precondition(!player.isPlaying && !player.isBuffering)
        precondition(currentQuery()["timeOffset"] == "40")
        player.resume()
        precondition(player.isPlaying && player.isBuffering)
        // Seeking backwards to zero must discard the previous stream's time offset.
        player.seek(to: 0)
        precondition(currentQuery()["timeOffset"] == "0")
        precondition(player.currentTime == 0)
        player.next()
        precondition(currentQuery()["id"] == "two")
        precondition(currentQuery()["timeOffset"] == nil)
        precondition(player.duration == 240)
        player.load([mp3], index: 0, position: 75, autoplay: false)
        precondition(currentQuery()["timeOffset"] == "75")
        precondition(!player.isPlaying && player.currentTime == 75)
        player.seek(to: .nan)
        precondition(player.currentTime == 75)
        // Seeking exactly to EOF must not request an empty stream and wait for readiness.
        player.load([mp3, flac], index: 0, position: 0, autoplay: false)
        player.seek(to: 300)
        precondition(player.currentSong?.id == "two" && !player.isPlaying)
        player.urlProvider = { _ in nil }
        player.load([mp3], index: 0, position: 100, autoplay: true)
        precondition(player.playbackError != nil && !player.isPlaying && !player.isBuffering)
        precondition(player.avPlayer.currentItem == nil)
        player.clear()
        precondition(player.avPlayer.currentItem == nil && !player.isBuffering)
        print("Seek regression checks passed")
    }
}
