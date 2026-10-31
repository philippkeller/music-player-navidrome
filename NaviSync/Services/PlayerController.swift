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
    /// Name of the current audio output when it isn't the device itself (e.g. "JBL Flip 5", "Kitchen").
    private(set) var externalOutputName: String?

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
    @ObservationIgnored var onEvent: ((PlayerEvent) -> Void)?
    /// (song, submission): submission=false is "now playing", true is a real scrobble.
    @ObservationIgnored var onScrobble: ((Song, Bool) -> Void)?

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
    /// The current item was recreated because a seek hung; don't retry again.
    @ObservationIgnored private var isRetryingSeek = false
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var didScrobble = false
    @ObservationIgnored private var wasInterrupted = false
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTick(time) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in self?.isBuffering = waiting }
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
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
                self?.updateOutputName()
            }
        })
        // Long-form audio routes like the Music app: AirPlay 2 speakers (incl. Sonos) get the
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
        loadCurrent(at: 0, autoplay: true)
        onEvent?(.trackChanged)
    }

    /// Restores a queue (e.g. from the server) without reporting it back as a change.
    func load(_ songs: [Song], index: Int, position: Double, autoplay: Bool) {
        guard songs.indices.contains(index) else { return }
        queue = songs
        currentIndex = index
        loadCurrent(at: position, autoplay: autoplay)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentSong != nil, !isPlaying else { return }
        if player.currentItem == nil {
            loadCurrent(at: currentTime, autoplay: true)
        } else if isSeeking {
            // A seek is still hanging: start over at the target instead of waiting on it.
            isRetryingSeek = true
            loadCurrent(at: currentTime, autoplay: true, announce: false)
        } else {
            startPlayback()
        }
        onEvent?(.started)
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
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
        guard currentSong != nil else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        isRetryingSeek = false
        if player.currentItem?.status == .readyToPlay {
            performSeek(to: target, allowReload: true)
        } else {
            pendingSeek = target
        }
        updateNowPlaying()
        onEvent?(.seeked)
    }

    func playNext(_ songs: [Song]) {
        guard let currentIndex else { play(songs); return }
        queue.insert(contentsOf: songs, at: currentIndex + 1)
        onEvent?(.queueChanged)
    }

    func addToQueue(_ songs: [Song]) {
        guard currentIndex != nil else { play(songs); return }
        queue.append(contentsOf: songs)
        onEvent?(.queueChanged)
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard let currentIndex else { return }
        let removable = offsets.filter { $0 != currentIndex && queue.indices.contains($0) }
        for index in removable.sorted(by: >) { queue.remove(at: index) }
        self.currentIndex = currentIndex - removable.filter { $0 < currentIndex }.count
        onEvent?(.queueChanged)
    }

    func clear() {
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
    private func loadCurrent(at position: Double, autoplay: Bool, announce: Bool = true) {
        guard let song = currentSong, let url = urlProvider?(song) else { return }
        seekGeneration += 1
        seekWatchdog?.cancel()
        if announce { isRetryingSeek = false }
        let item = AVPlayerItem(url: url)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        }
        pendingSeek = position > 0 ? position : nil
        isSeeking = false
        currentTime = position
        duration = Double(song.duration ?? 0)
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
        if announce { loadArtwork(for: song) }
    }

    private func performSeek(to target: Double, allowReload: Bool) {
        guard let item = player.currentItem else { return }
        item.cancelPendingSeeks()
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        // A little tolerance lets AVPlayer seek to the nearest frame it can reach quickly,
        // instead of decoding forward through a long VBR stream.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor in
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
                if finished, self.isPlaying { self.player.play() }
            }
        }

        // Seeking into a part of the stream that isn't buffered yet sometimes never completes,
        // or completes but playback never resumes. Recreate the item at the target in that case.
        seekWatchdog?.cancel()
        guard allowReload else { return }
        seekWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, generation == self.seekGeneration else { return }
            let stuck = self.isSeeking || (self.isPlaying && self.player.timeControlStatus != .playing)
            guard stuck else { return }
            print("Seek to \(target)s hung, reloading the item")
            self.isRetryingSeek = true
            self.loadCurrent(at: target, autoplay: self.isPlaying, announce: false)
        }
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
        if pendingSeek == nil { player.play() }
        updateNowPlaying()
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
            if let target = pendingSeek {
                pendingSeek = nil
                performSeek(to: target, allowReload: !isRetryingSeek)
                isRetryingSeek = false
            }
            updateNowPlaying()
        case .failed:
            print("Playback failed: \(item.error?.localizedDescription ?? "unknown error")")
            if isPlaying, hasNext {
                next()
            } else {
                isPlaying = false
                updateNowPlaying()
            }
        default:
            break
        }
    }

    private func handleTick(_ time: CMTime) {
        guard !isSeeking, pendingSeek == nil else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = seconds
        guard isPlaying else { return }
        tickCount += 1
        if tickCount % 20 == 0 { onEvent?(.tick) } // every ~10 s
        if !didScrobble, let song = currentSong, duration > 0, seconds > min(duration / 2, 240) {
            didScrobble = true
            onScrobble?(song, true)
        }
    }

    private func trackFinished() {
        if !didScrobble, let song = currentSong {
            didScrobble = true
            onScrobble?(song, true)
        }
        if let currentIndex, hasNext {
            self.currentIndex = currentIndex + 1
            loadCurrent(at: 0, autoplay: true)
            onEvent?(.trackChanged)
        } else {
            player.pause()
            player.seek(to: .zero)
            isPlaying = false
            currentTime = 0
            updateNowPlaying()
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
        guard let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch interruption {
        case .began:
            if isPlaying {
                wasInterrupted = true
                isPlaying = false
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
        let center = MPNowPlayingInfoCenter.default()
        guard let song = currentSong else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
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
