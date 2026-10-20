import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Memory + disk cache for cover art, so artwork also shows up offline.
@MainActor
final class CoverArtCache {
    static let shared = CoverArtCache()

    var client: SubsonicClient?

    private let memory = NSCache<NSString, PlatformImage>()
    private var inflight: [String: Task<Data?, Never>] = [:]
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoverArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        memory.countLimit = 300
    }

    func image(for id: String?) async -> PlatformImage? {
        guard let id, !id.isEmpty else { return nil }
        if let cached = memory.object(forKey: id as NSString) { return cached }
        let task: Task<Data?, Never>
        if let existing = inflight[id] {
            task = existing
        } else {
            let fileURL = directory.appendingPathComponent(DiskStore.safeName(id))
            let remoteURL = client?.coverArtURL(id: id)
            task = Task.detached(priority: .utility) { () -> Data? in
                if let data = try? Data(contentsOf: fileURL) { return data }
                guard let remoteURL, let result = try? await URLSession.shared.data(from: remoteURL) else { return nil }
                let (data, response) = result
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
                if response.mimeType?.hasPrefix("image") == false { return nil }
                try? data.write(to: fileURL, options: .atomic)
                return data
            }
            inflight[id] = task
        }
        let data = await task.value
        inflight[id] = nil
        if let cached = memory.object(forKey: id as NSString) { return cached }
        guard let data, let image = PlatformImage(data: data) else { return nil }
        memory.setObject(image, forKey: id as NSString)
        return image
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }
}

struct CoverArtView: View {
    let coverArtId: String?
    var cornerRadius: CGFloat = 6

    @State private var image: PlatformImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: coverArtId) {
                image = await CoverArtCache.shared.image(for: coverArtId)
            }
    }
}
