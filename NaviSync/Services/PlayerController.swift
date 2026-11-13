import AVFoundation
import MediaPlayer
import Observation

enum PlayerEvent {
    case trackChanged, started, paused, seeked, queueChanged, tick
}

/// Plays a queue of songs with AVPlayer and drives lock screen / Control Center / media keys.
@MainActor
@Observable
final class PlayerController {
    private(set) var queue: [Song] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Playback is wanted but AVPlayer is waiting for data (e.g. after seeking into an unbuffered part).
    private(set) var isBuffering = false
    private(set) var playbackError: String?
    /// Name of the current audio output when it isn't the device itself (e.g. "JBL Flip 5", "Kitchen").
    private(set) var externalOutputName: String?
    /// The Sonos room playing the queue instead of this device.
    private(set) var sonosRoom: SonosRoom?
    private(set) var sonosVolume: Double = 0
    private(set) var sonosError: String?

    var currentSong: Song? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var hasNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < queue.count
    }

    /// Returns the local file if downloaded, otherwise the stream URL.
    @ObservationIgnored var urlProvider: ((Song) -> URL?)?
    @ObservationIgnored var offsetStreamURLProvider: ((Song, Double) -> URL?)?
    /// The stream Sonos should play (never a local file, the speaker can't reach those).
    @ObservationIgnored var sonosTrackProvider: ((Song) -> SonosTrack?)?
    @ObservationIgnored var onEvent: ((PlayerEvent) -> Void)?
    /// (song, submission): submission=false is "now playing", true is a real scrobble.
    @ObservationIgnored var onScrobble: ((Song, Bool) -> Void)?
    /// Song title playing at a position of a continuous album file (from the lyrics), for the lock screen.
    @ObservationIgnored var sectionTitleProvider: ((Song, Double) -> String?)?
    @ObservationIgnored private var nowPlayingTitle: String?

    @ObservationIgnored private let player = AVPlayer()
    /// Exposed for the macOS AirPlay picker, which routes a specific player.
    var avPlayer: AVPlayer { player }
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var isSeeking = false
    /// Bumped on every seek and item change, so stale seek completions and watchdogs are ignored.
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var seekWatchdog: Task<Void, Never>?
    @ObservationIgnored private var recoveryAttempts = 0
    /// The server starts offset streams at this absolute song position.
    @ObservationIgnored private var streamOffset: Double = 0
    @ObservationIgnored private var usesOffsetStream = false
    @ObservationIgnored private var mp3Loader: MP3OffsetLoader?
    #if os(iOS)
    @ObservationIgnored private var silence: AVAudioPlayer?
    @ObservationIgnored private var routeBeforePicker: String?
    @ObservationIgnored private var routePickedAt: Date?
    #endif
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var didScrobble = false
    @ObservationIgnored private var wasInterrupted = false
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// The speaker's queue doesn't match `queue` yet.
    @ObservationIgnored private var sonosQueueIsStale = false
    /// Commands run strictly one after the other.
    @ObservationIgnored private var sonosCommands: Task<Void, Never>?
    @ObservationIgnored private var sonosPendingCommands = 0
    /// Bumped on every command, so a status fetched before it isn't applied after it.
    @ObservationIgnored private var sonosGeneration = 0
    /// The speaker reports old values right after a command.
    @ObservationIgnored private var sonosSettleUntil = Date.distantPast
    @ObservationIgnored private var sonosFailures = 0
    @ObservationIgnored private var sonosPoll: Task<Void, Never>?
    @ObservationIgnored private var pendingSonosVolume: Int?
    @ObservationIgnored private var sonosVolumeTask: Task<Void, Never>?
    /// A status read shortly after changing the volume may still have the old value.
    @ObservationIgnored private var sonosVolumeChanged = Date.distantPast
    #if os(iOS)
    /// Sets the iPhone's own volume; provided by `SonosVolumeKeys` while it's on screen.
    @ObservationIgnored var setSystemVolume: ((Float) -> Void)?
    @ObservationIgnored private var volumeKeyObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastOutputVolume: Float = 0
    /// The value we set ourselves, whose change isn't a key press.
    @ObservationIgnored private var recenterTarget: Float?
    /// The iPhone's volume before recentering, restored when leaving Sonos.
    @ObservationIgnored private var volumeBeforeRecenter: Float?
    #endif

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTick(time) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateBuffering() }
        }

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, item === self.player.currentItem else { return }
                self.trackFinished()
            }
        })

        #if os(iOS)
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones unplugged: AVPlayer pauses itself, keep our state in sync.
                if self?.sonosRoom == nil, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
                self?.updateOutputName()
                self?.leaveSonosIfRouteChanged()
            }
        })
        // Long-form audio routes like the Music app: AirPlay 2 speakers get the
        // whole stream buffered instead of being mirrored as system audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        updateOutputName()
        #endif

        setupRemoteCommands()
    }

    // MARK: Public controls

    func play(_ songs: [Song], startAt index: Int = 0) {
        guard songs.indices.contains(index) else { return }
        queue = songs
        currentIndex = index
        sonosQueueIsStale = true
        loadCurrent(at: 0, autoplay: true)
        onEvent?(.trackChanged)
    }

    /// Restores a queue (e.g. from the server) without reporting it back as a change.
    func load(_ songs: [Song], index: Int, position: Double, autoplay: Bool) {
        guard songs.indices.contains(index) else { return }
        queue = songs
        currentIndex = index
        sonosQueueIsStale = true
        loadCurrent(at: position, autoplay: autoplay)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentSong != nil, !isPlaying else { return }
        if sonosRoom != nil {
            isPlaying = true
            updateNowPlaying()
            sonos { try await $0.play() }
        } else if player.currentItem == nil {
            loadCurrent(at: currentTime, autoplay: true, announce: false)
        } else if playbackError != nil {
            loadCurrent(at: currentTime, autoplay: true, announce: false)
        } else {
            recoveryAttempts = 0
            startPlayback()
        }
        onEvent?(.started)
    }

    func pause() {
        guard isPlaying else { return }
        if sonosRoom != nil {
            sonos { try await $0.pause() }
        } else {
            player.pause()
        }
        isPlaying = false
        updateBuffering()
        updateNowPlaying()
        onEvent?(.paused)
    }

    func next() {
        guard let currentIndex, hasNext else { return }
        self.currentIndex = currentIndex + 1
        loadCurrent(at: 0, autoplay: isPlaying)
        onEvent?(.trackChanged)
    }

    func previous() {
        guard let currentIndex else { return }
        if currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
            return
        }
        self.currentIndex = currentIndex - 1
        loadCurrent(at: 0, autoplay: isPlaying)
        onEvent?(.trackChanged)
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrent(at: 0, autoplay: true)
        onEvent?(.trackChanged)
    }

    func seek(to seconds: Double) {
        guard currentSong != nil, seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        playbackError = nil
        recoveryAttempts = 0
        if sonosRoom != nil {
            sonos { try await $0.seek(to: target) }
        } else if duration > 0, target >= duration {
            // An offset stream starting at EOF contains no audio and cannot become ready.
            resetSeek()
            trackFinished()
        } else if let song = currentSong, let url = urlProvider?(song), !url.isFileURL {
            loadCurrent(at: target, autoplay: isPlaying, announce: false)
        } else if usesOffsetStream || player.currentItem == nil || player.currentItem?.status == .failed {
            loadCurrent(at: target, autoplay: isPlaying, announce: false)
        } else if player.currentItem?.status == .readyToPlay {
            performSeek(to: target)
        } else {
            pendingSeek = target
            player.pause()
            watchPlaybackProgress()
        }
        updateBuffering()
        updateNowPlaying()
        onEvent?(.seeked)
    }

    func playNext(_ songs: [Song]) {
        guard let currentIndex else { play(songs); return }
        queue.insert(contentsOf: songs, at: currentIndex + 1)
        addToSonosQueue(songs, at: currentIndex + 2)
        onEvent?(.queueChanged)
    }

    func addToQueue(_ songs: [Song]) {
        guard currentIndex != nil else { play(songs); return }
        queue.append(contentsOf: songs)
        addToSonosQueue(songs, at: 0)
        onEvent?(.queueChanged)
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard let currentIndex else { return }
        let removable = offsets.filter { $0 != currentIndex && queue.indices.contains($0) }
        let descending = removable.sorted(by: >)
        for index in descending { queue.remove(at: index) }
        sonos { client in
            for index in descending { try await client.removeTrack(at: index) }
        }
        self.currentIndex = currentIndex - removable.filter { $0 < currentIndex }.count
        onEvent?(.queueChanged)
    }

    func clear() {
        disconnectSonos()
        resetSeek()
        playbackError = nil
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        queue = []
        currentIndex = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        updateNowPlaying()
    }

    // MARK: Internals

    /// - Parameter announce: false when only recreating the item of the same song
    ///   (keeps artwork and doesn't send another "now playing" scrobble).
    private func loadCurrent(at position: Double, autoplay: Bool, announce: Bool = true, serverSeek: Bool = false, recovering: Bool = false) {
        if sonosRoom != nil {
            loadOnSonos(at: position, autoplay: autoplay, announce: announce)
            return
        }
        guard let song = currentSong else { return }
        resetSeek()
        if !recovering { recoveryAttempts = 0 }
        currentTime = position
        guard let originalURL = urlProvider?(song) else {
            failSeek()
            return
        }
        playbackError = nil
        usesOffsetStream = !originalURL.isFileURL && (position > 0 || serverSeek)
        streamOffset = usesOffsetStream ? floor(position) : 0
        let asset: AVURLAsset
        if usesOffsetStream, let loader = MP3OffsetLoader(source: originalURL, song: song, position: position) {
            // Raw MP3 from a byte offset: original quality and range requests, no transcoding.
            mp3Loader = loader
            streamOffset = position
            asset = loader.asset
        } else if usesOffsetStream {
            guard let streamURL = offsetStreamURLProvider?(song, streamOffset) else {
                failSeek()
                return
            }
            asset = AVURLAsset(url: streamURL)
        } else {
            asset = AVURLAsset(url: originalURL)
        }
        let item = AVPlayerItem(asset: asset)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        }
        pendingSeek = !usesOffsetStream && position > 0 ? position : nil
        isSeeking = usesOffsetStream
        currentTime = position
        if announce || duration <= 0 { duration = Double(song.duration ?? 0) }
        if announce {
            didScrobble = false
            tickCount = 0
        }
        player.replaceCurrentItem(with: item)
        if autoplay {
            startPlayback()
            if announce { onScrobble?(song, false) }
        } else {
            player.pause()
            isPlaying = false
            updateNowPlaying()
        }
        watchPlaybackProgress()
        if announce { loadArtwork(for: song) }
    }

    /// Keep monitoring after playback starts: AVPlayer can report playing without advancing.
    private func watchPlaybackProgress() {
        seekWatchdog?.cancel()
        let generation = seekGeneration
        let start = player.currentTime().seconds
        seekWatchdog = Task { [weak self] in
            var progress = PlaybackProgressWatchdog(now: ProcessInfo.processInfo.systemUptime, position: start)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, generation == self.seekGeneration, self.sonosRoom == nil,
                      self.playbackError == nil else { return }
                let positioning = self.isSeeking || self.pendingSeek != nil
                let needsProgress = self.isPlaying || positioning
                let position = self.player.currentTime().seconds
                let stalled = progress.check(now: ProcessInfo.processInfo.systemUptime,
                                             position: position, active: needsProgress,
                                             positioned: !positioning)
                if progress.advancedSeconds >= 5 { self.recoveryAttempts = 0 }
                if stalled {
                    self.recoverPlayback()
                    return
                }
                // Restart the renderer when data arrives after a network or output stall.
                if self.isPlaying, !positioning, self.player.currentItem?.status == .readyToPlay,
                   self.player.timeControlStatus != .playing {
                    self.player.playImmediately(atRate: 1)
                }
                self.updateBuffering()
            }
        }
    }

    private func recoverPlayback() {
        guard sonosRoom == nil, currentSong != nil else { return }
        guard recoveryAttempts < 2 else {
            failSeek()
            return
        }
        recoveryAttempts += 1
        loadCurrent(at: currentTime, autoplay: isPlaying, announce: false,
                    serverSeek: true, recovering: true)
    }

    private func updateBuffering() {
        guard sonosRoom == nil else { return }
        isBuffering = isPlaying && (isSeeking || pendingSeek != nil ||
            player.timeControlStatus != .playing)
    }

    /// Called whenever the current item is about to be replaced or dropped.
    private func resetSeek() {
        mp3Loader?.cancel()
        mp3Loader = nil
        seekGeneration += 1
        seekWatchdog?.cancel()
        seekWatchdog = nil
        player.currentItem?.cancelPendingSeeks()
        pendingSeek = nil
        isSeeking = false
        isBuffering = false
    }

    private func failSeek() {
        resetSeek()
        player.pause()
        itemStatusObservation = nil
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        playbackError = "Couldn't load this position. Press play to retry."
        updateNowPlaying()
        onEvent?(.paused)
    }

    private func performSeek(to target: Double) {
        guard let item = player.currentItem else { return }
        seekGeneration += 1
        let generation = seekGeneration
        item.cancelPendingSeeks()
        seekWatchdog?.cancel()
        pendingSeek = nil
        isSeeking = true
        player.pause()
        updateBuffering()
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor in
                guard let self, generation == self.seekGeneration else { return }
                guard finished else {
                    self.recoverPlayback()
                    return
                }
                self.isSeeking = false
                if self.isPlaying { self.player.playImmediately(atRate: 1) }
                self.updateBuffering()
            }
        }
        watchPlaybackProgress()
    }

    private func startPlayback() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        updateOutputName()
        #endif
        isPlaying = true
        // With a pending seek we start playing once the item is ready and positioned.
        if pendingSeek == nil, !isSeeking { player.playImmediately(atRate: 1) }
        watchPlaybackProgress()
        updateBuffering()
        updateNowPlaying()
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem, playbackError == nil else { return }
        switch item.status {
        case .readyToPlay:
            let itemDuration = item.duration.seconds
            // A timestamp stream contains only the remainder; its duration is not the song duration.
            if !usesOffsetStream, itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
            if usesOffsetStream {
                isSeeking = false
                if isPlaying { player.playImmediately(atRate: 1) }
                updateBuffering()
            }
            if let target = pendingSeek {
                pendingSeek = nil
                performSeek(to: target)
            }
            updateNowPlaying()
        case .failed:
            print("Playback failed: \(item.error?.localizedDescription ?? "unknown error")")
            recoverPlayback()
        default:
            break
        }
    }

    private func handleTick(_ time: CMTime) {
        guard sonosRoom == nil, !isSeeking, pendingSeek == nil, playbackError == nil,
              player.currentItem?.status == .readyToPlay else { return }
        // A queued callback may belong to the replaced item. Read the current item's clock.
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        currentTime = streamOffset + seconds
        if let song = currentSong, nowPlayingTitle != (sectionTitleProvider?(song, currentTime) ?? song.title) {
            updateNowPlaying()
        }
        guard isPlaying else { return }
        tickCount += 1
        if tickCount % 20 == 0 { onEvent?(.tick) } // every ~10 s
        if !didScrobble, let song = currentSong, duration > 0, currentTime > min(duration / 2, 240) {
            didScrobble = true
            onScrobble?(song, true)
        }
    }

    private func trackFinished() {
        guard !isSeeking, pendingSeek == nil, playbackError == nil else { return }
        seekGeneration += 1
        seekWatchdog?.cancel()
        if !didScrobble, let song = currentSong {
            didScrobble = true
            onScrobble?(song, true)
        }
        if let currentIndex, hasNext {
            self.currentIndex = currentIndex + 1
            loadCurrent(at: 0, autoplay: isPlaying)
            onEvent?(.trackChanged)
        } else {
            loadCurrent(at: 0, autoplay: false, announce: false)
            onEvent?(.paused)
        }
    }

    #if os(iOS)
    private func updateOutputName() {
        let local: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver]
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        externalOutputName = output.flatMap { local.contains($0.portType) ? nil : $0.portName }
    }

    private func handleInterruption(type: UInt?, options: UInt?) {
        if sonosRoom != nil {
            // A call stops the silent keep-alive, while the speaker keeps playing.
            if type == AVAudioSession.InterruptionType.ended.rawValue { updateSilence() }
            return
        }
        // A phone call doesn't stop the speaker.
        guard sonosRoom == nil, let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch interruption {
        case .began:
            if isPlaying {
                wasInterrupted = true
                isPlaying = false
                player.pause()
                updateBuffering()
                updateNowPlaying()
                onEvent?(.paused)
            }
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options ?? 0).contains(.shouldResume)
            if wasInterrupted, shouldResume { resume() }
            wasInterrupted = false
        @unknown default:
            break
        }
    }
    #endif

    // MARK: Now playing / remote commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        #if os(iOS)
        updateSilence()
        #endif
        let center = MPNowPlayingInfoCenter.default()
        guard let song = currentSong else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        let title = sectionTitleProvider?(song, currentTime) ?? song.title
        nowPlayingTitle = title
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func loadArtwork(for song: Song) {
        artwork = nil
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await CoverArtCache.shared.image(for: song.coverArt) else { return }
            guard let self, !Task.isCancelled, self.currentSong?.id == song.id else { return }
            self.artwork = Self.makeArtwork(image)
            self.updateNowPlaying()
        }
    }

    /// Nonisolated on purpose: MediaPlayer calls the request handler on a background thread.
    nonisolated private static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

// MARK: - Sonos

/// While a room is selected the speaker plays its own copy of the queue and streams from the server.
/// This class only sends commands and mirrors what the speaker reports, so sync and scrobbling keep working.
extension PlayerController {
    private static let sonosRoomKey = "sonosRoom"

    func connectSonos(_ room: SonosRoom) {
        guard room != sonosRoom else { return }
        sonos { try await $0.pause() }
        attachSonos(room)
        sonosQueueIsStale = true
        if currentSong != nil { loadCurrent(at: currentTime, autoplay: isPlaying, announce: false) }
    }

    /// Back to this device, continuing where the speaker was.
    func disconnectSonos() {
        guard sonosRoom != nil else { return }
        let wasPlaying = isPlaying
        sonos { try await $0.pause() }
        detachSonos()
        isPlaying = false
        if wasPlaying { loadCurrent(at: currentTime, autoplay: true, announce: false) }
        updateNowPlaying()
    }

    /// After a restart: picks the speaker up again if it's still playing our queue.
    func reconnectSonos() {
        guard let data = UserDefaults.standard.data(forKey: Self.sonosRoomKey),
              let room = try? JSONDecoder().decode(SonosRoom.self, from: data) else { return }
        Task { [weak self] in
            let status = try? await SonosClient(host: room.host).status()
            guard let self, self.sonosRoom == nil, !self.isPlaying else { return }
            guard let status, status.isPlaying, status.isPlayingQueue(of: room),
                  self.queue.contains(where: { $0.id == status.songID }) else {
                UserDefaults.standard.removeObject(forKey: Self.sonosRoomKey)
                return
            }
            self.attachSonos(room)
            self.apply(status, room: room)
        }
    }

    func setSonosVolume(_ volume: Double) {
        sonosVolume = volume
        sonosVolumeChanged = Date()
        pendingSonosVolume = Int(volume.rounded())
        guard sonosVolumeTask == nil, let room = sonosRoom else { return }
        // Sends only the latest value, so dragging never queues up requests.
        sonosVolumeTask = Task { [weak self] in
            while let target = self?.pendingSonosVolume {
                self?.pendingSonosVolume = nil
                try? await SonosClient(host: room.host).setVolume(target)
            }
            self?.sonosVolumeTask = nil
        }
    }

    func refreshSonosVolume() async {
        guard let room = sonosRoom, let volume = try? await SonosClient(host: room.host).volume(),
              room == sonosRoom, sonosVolumeTask == nil,
              Date().timeIntervalSince(sonosVolumeChanged) > 2 else { return }
        sonosVolume = Double(volume)
    }

    /// The app is in front again: iOS may have deactivated the audio session the volume keys rely on.
    func sonosAppBecameActive() {
        guard sonosRoom != nil else { return }
        #if os(iOS)
        watchVolumeKeys()
        #endif
    }

    #if os(iOS)
    /// iOS only shows lock screen controls (and passes on volume keys in the background) while the
    /// app plays audio itself. The speaker streams from the server, so play silence while it plays.
    private func updateSilence() {
        let wanted = sonosRoom != nil && isPlaying
        if wanted, silence?.isPlaying != true {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try? session.setActive(true)
            if silence == nil {
                silence = try? AVAudioPlayer(data: Self.silentWAV)
                silence?.numberOfLoops = -1
            }
            silence?.play()
        } else if !wanted, silence?.isPlaying == true {
            silence?.pause()
        }
    }

    func routePickerWillPresent() {
        routeBeforePicker = currentRouteID()
    }

    func routePickerDidDismiss() {
        routePickedAt = Date()
        leaveSonosIfRouteChanged()
    }

    /// An output picked in the system picker while on Sonos (the silence keeps our session active,
    /// so the picker moves it): continue there instead. The route can change shortly after the
    /// picker closes, so route changes within a few seconds count too.
    fileprivate func leaveSonosIfRouteChanged() {
        guard sonosRoom != nil, let picked = routePickedAt, Date().timeIntervalSince(picked) < 5,
              let before = routeBeforePicker, currentRouteID() != before else { return }
        routePickedAt = nil
        disconnectSonos()
    }

    private func currentRouteID() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid).joined(separator: ",")
    }

    /// One second of 8 kHz mono 16-bit silence.
    private static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000
        let dataSize = sampleRate * 2
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }()

    /// iOS has no API for the volume keys, but they change the output volume while our audio session
    /// is active. Those changes are passed on to the speaker.
    private func watchVolumeKeys() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        lastOutputVolume = session.outputVolume
        recenterIfAtLimit()
        volumeKeyObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor in self?.outputVolumeChanged(volume) }
        }
    }

    private func outputVolumeChanged(_ volume: Float) {
        guard sonosRoom != nil else { return }
        let delta = volume - lastOutputVolume
        lastOutputVolume = volume
        if let target = recenterTarget, abs(volume - target) < 0.01 {
            recenterTarget = nil
            return
        }
        guard abs(delta) > 0.001 else { return }
        // One key press is 1/16 of the range, which makes 4 on the speaker's 0–100.
        let step = (Double(delta) * 64).rounded()
        setSonosVolume(min(100, max(0, sonosVolume + (step == 0 ? (delta > 0 ? 1 : -1) : step))))
        recenterIfAtLimit()
    }

    /// At the iPhone's minimum or maximum a key press changes nothing, so we wouldn't see it.
    func recenterIfAtLimit() {
        guard sonosRoom != nil, let setSystemVolume, lastOutputVolume <= 0.01 || lastOutputVolume >= 0.99 else { return }
        if volumeBeforeRecenter == nil { volumeBeforeRecenter = lastOutputVolume }
        recenterTarget = 0.5
        setSystemVolume(0.5)
    }

    private func stopWatchingVolumeKeys() {
        volumeKeyObservation = nil
        recenterTarget = nil
        if let volumeBeforeRecenter { setSystemVolume?(volumeBeforeRecenter) }
        volumeBeforeRecenter = nil
    }
    #endif

    private func attachSonos(_ room: SonosRoom) {
        resetSeek()
        playbackError = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        sonosRoom = room
        sonosError = nil
        sonosFailures = 0
        UserDefaults.standard.set(try? JSONEncoder().encode(room), forKey: Self.sonosRoomKey)
        sonosPoll?.cancel()
        sonosPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollSonos()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task { await refreshSonosVolume() }
        #if os(iOS)
        watchVolumeKeys()
        #endif
    }

    private func detachSonos() {
        #if os(iOS)
        stopWatchingVolumeKeys()
        silence?.stop()
        #endif
        sonosPoll?.cancel()
        sonosRoom = nil
        isBuffering = false
        UserDefaults.standard.removeObject(forKey: Self.sonosRoomKey)
    }

    /// Queues a command for the current room. Failures show up next to the output name.
    private func sonos(_ action: @escaping @MainActor (SonosClient) async throws -> Void) {
        guard let room = sonosRoom else { return }
        let previous = sonosCommands
        sonosGeneration += 1
        sonosPendingCommands += 1
        sonosCommands = Task { [weak self] in
            _ = await previous?.value
            do {
                try await action(SonosClient(host: room.host))
                self?.sonosError = nil
            } catch {
                self?.sonosError = "\(room.name): \(error.localizedDescription)"
            }
            self?.sonosPendingCommands -= 1
            self?.sonosSettleUntil = Date().addingTimeInterval(1)
        }
    }

    private func loadOnSonos(at position: Double, autoplay: Bool, announce: Bool) {
        guard let song = currentSong, let index = currentIndex, let room = sonosRoom,
              let sonosTrackProvider else { return }
        let tracks = sonosQueueIsStale ? queue.compactMap(sonosTrackProvider) : nil
        sonosQueueIsStale = false
        currentTime = position
        duration = Double(song.duration ?? 0)
        isPlaying = autoplay
        if announce {
            didScrobble = false
            tickCount = 0
            if autoplay { onScrobble?(song, false) }
            loadArtwork(for: song)
        }
        updateNowPlaying()
        sonos { [weak self] client in
            do {
                if let tracks { try await client.replaceQueue(tracks, speakerID: room.id) }
                try await client.start(index: index, at: position, play: autoplay)
            } catch {
                if tracks != nil { self?.sonosQueueIsStale = true }
                throw error
            }
        }
    }

    private func addToSonosQueue(_ songs: [Song], at position: Int) {
        guard let sonosTrackProvider else { return }
        let tracks = songs.compactMap(sonosTrackProvider)
        sonos { try await $0.add(tracks, at: position) }
    }

    private func pollSonos() async {
        guard let room = sonosRoom, sonosPendingCommands == 0, Date() >= sonosSettleUntil else { return }
        let generation = sonosGeneration
        do {
            let status = try await SonosClient(host: room.host).status()
            guard room == sonosRoom, generation == sonosGeneration else { return }
            sonosFailures = 0
            apply(status, room: room)
            await refreshSonosVolume()
        } catch {
            guard room == sonosRoom else { return }
            sonosFailures += 1
            if sonosFailures >= 5 { lostSonos("\(room.name) can't be reached.") }
        }
    }

    private func apply(_ status: SonosStatus, room: SonosRoom) {
        guard status.isPlayingQueue(of: room) else {
            lostSonos("\(room.name) is playing something else now.")
            return
        }
        if let id = status.songID {
            let index = status.track - 1
            let found = queue.indices.contains(index) && queue[index].id == id
                ? index : queue.firstIndex { $0.id == id }
            guard let found else {
                lostSonos("\(room.name) is playing something else now.")
                return
            }
            if found != currentIndex {
                currentIndex = found
                didScrobble = false
                tickCount = 0
                let song = queue[found]
                duration = Double(song.duration ?? 0)
                onScrobble?(song, false)
                loadArtwork(for: song)
                onEvent?(.trackChanged)
            }
        }
        isBuffering = status.isBuffering
        currentTime = status.position
        if status.duration > 0 { duration = status.duration }
        if status.isPlaying != isPlaying {
            isPlaying = status.isPlaying
            onEvent?(isPlaying ? .started : .paused)
        }
        updateNowPlaying()
        guard isPlaying else { return }
        tickCount += 1
        if tickCount % 10 == 0 { onEvent?(.tick) } // every ~10 s
        if !didScrobble, let song = currentSong, duration > 0, currentTime > min(duration / 2, 240) {
            didScrobble = true
            onScrobble?(song, true)
        }
    }

    /// The speaker went away or someone else took it over: leave it alone and stop here too.
    private func lostSonos(_ message: String) {
        detachSonos()
        isPlaying = false
        sonosError = message
        updateNowPlaying()
    }
}
