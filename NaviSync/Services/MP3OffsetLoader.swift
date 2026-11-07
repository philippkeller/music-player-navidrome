import AVFoundation
import Foundation

/// Plays a remote MP3 from a byte offset, so seeking never depends on AVPlayer scanning the stream.
///
/// AVPlayer sees a file that starts at the offset and fetches it with ordinary range requests against
/// the raw file. MP3 decoders resync on the next frame, so starting mid-frame is fine.
/// Navidrome only honors `timeOffset` when transcoding, and its transcoded streams don't support ranges.
final class MP3OffsetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let scheme = "navisync-mp3"

    let asset: AVURLAsset
    private let source: URL
    private let fileSize: Int64
    private let fraction: Double
    // All state below is only touched on `queue` (resource loader and session callbacks both run there).
    private let queue = DispatchQueue(label: "NaviSync.MP3OffsetLoader")
    private var session: URLSession!
    private var offset: Int64?
    private var waiting: [AVAssetResourceLoadingRequest] = []
    private var loads: [Int: (task: URLSessionDataTask, request: AVAssetResourceLoadingRequest)] = [:]

    /// Returns nil when the song isn't a remote MP3 of known size and duration.
    init?(source: URL, song: Song, position: Double) {
        guard !source.isFileURL, song.suffix?.lowercased() == "mp3",
              let size = song.size, size > 0, let duration = song.duration, duration > 0,
              position > 0, position < Double(duration),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = Self.scheme
        guard let url = components.url else { return nil }
        self.source = source
        fileSize = Int64(size)
        fraction = position / Double(duration)
        asset = AVURLAsset(url: url)
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        asset.resourceLoader.setDelegate(self, queue: queue)
        fetchAudioStart()
    }

    /// Must be called when the item is replaced: the session retains this object.
    func cancel() {
        session.invalidateAndCancel()
    }

    /// Skips the ID3 tag (often large because of embedded artwork) so the offset maps to audio time.
    private func fetchAudioStart() {
        var request = URLRequest(url: source)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        session.dataTask(with: request) { [weak self] data, _, _ in
            self?.start(header: data ?? Data())
        }.resume()
    }

    private func start(header: Data) {
        let b = [UInt8](header.prefix(10))
        var audioStart: Int64 = 0
        if b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { // "ID3"
            let tagSize = Int64(b[6] & 0x7f) << 21 | Int64(b[7] & 0x7f) << 14 | Int64(b[8] & 0x7f) << 7 | Int64(b[9] & 0x7f)
            audioStart = 10 + tagSize + (b[5] & 0x10 != 0 ? 10 : 0)
        }
        if audioStart >= fileSize { audioStart = 0 }
        offset = min(fileSize - 1, audioStart + Int64(Double(fileSize - audioStart) * fraction))
        let pending = waiting
        waiting = []
        pending.forEach(load)
    }

    private func load(_ request: AVAssetResourceLoadingRequest) {
        guard let offset else { return }
        let length = fileSize - offset
        if let info = request.contentInformationRequest {
            info.contentType = "public.mp3"
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        let start = dataRequest.currentOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? length - 1
            : min(length - 1, dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1)
        guard start <= end else {
            request.finishLoading()
            return
        }
        var urlRequest = URLRequest(url: source)
        urlRequest.setValue("bytes=\(offset + start)-\(offset + end)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: urlRequest)
        loads[task.taskIdentifier] = (task, request)
        task.resume()
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if offset == nil { waiting.append(loadingRequest) } else { load(loadingRequest) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        waiting.removeAll { $0 === loadingRequest }
        for (id, load) in loads where load.request === loadingRequest {
            loads[id] = nil
            load.task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            loads.removeValue(forKey: dataTask.taskIdentifier)?.request.finishLoading(with: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        loads[dataTask.taskIdentifier]?.request.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = loads.removeValue(forKey: task.taskIdentifier)?.request else { return }
        if let error { request.finishLoading(with: error) } else { request.finishLoading() }
    }
}
