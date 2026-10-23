import AVFoundation
import CoreImage
import Foundation
import ImageIO
import MediaPlayer
import UIKit
import SDWebImage

/// Produces a bitmap-backed artwork image for the system player. This is kept
/// separate from Share rendering and never changes the on-screen cover.
@MainActor
enum NowPlayingArtworkLoader {
    static func officialLogo() -> MPMediaItemArtwork? {
        UIImage(named: "NightcoreLogo").flatMap(artwork)
    }

    static func load(coverURL: URL?, mediaURL: URL?,
                     fallbackCoverURLs: [URL] = []) async -> MPMediaItemArtwork? {
        var seen = Set<URL>()
        let candidates = ([coverURL].compactMap { $0 } + fallbackCoverURLs)
            .filter { seen.insert($0).inserted }
        // Prefer the real cover, then a stable alternate. Retry transient CDN
        // failures before publishing the generic logo to the lock screen.
        for attempt in 0..<3 where !Task.isCancelled {
            for candidate in candidates {
                guard !Task.isCancelled else { return nil }
                if let image = await coverImage(at: candidate),
                   !Task.isCancelled, let cover = artwork(image) {
                    return cover
                }
            }
            guard attempt < 2, !candidates.isEmpty else { break }
            do {
                try await Task.sleep(for: .seconds(attempt == 0 ? 1.5 : 4))
            } catch {
                return nil
            }
        }
        if let mediaURL, mediaURL.isFileURL,
           ["mp4", "m4v", "mov"].contains(mediaURL.pathExtension.lowercased()),
           let frame = await Task.detached(priority: .utility, operation: {
               videoFrameData(at: mediaURL)
           }).value,
           !Task.isCancelled, let image = image(from: frame) {
            return artwork(image)
        }
        return nil
    }

    static func coverImage(at url: URL) async -> UIImage? {
        await PlayerArtworkStore.shared.image(at: url)
    }

    static func coverData(at url: URL) async -> Data? {
        await PlayerArtworkStore.shared.data(at: url)
    }

    static func releaseDecodedCovers() async {
        SDImageCache.shared.clearMemory()
        await PlayerArtworkStore.shared.removeAll()
    }

    nonisolated private static func videoFrameData(at url: URL) -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_024, height: 1_024)
        let image = (try? generator.copyCGImage(
            at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)) ??
            (try? generator.copyCGImage(at: .zero, actualTime: nil))
        guard let image, let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    nonisolated static func image(from data: Data) -> UIImage? {
        guard data.count <= 6 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                               options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func artwork(_ image: UIImage) -> MPMediaItemArtwork? {
        let source = image.cgImage ?? image.ciImage.flatMap {
            CIContext().createCGImage($0, from: $0.extent)
        }
        guard let source else { return nil }
        let side: CGFloat = 512
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                             format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = max(side / CGFloat(source.width), side / CGFloat(source.height))
            let width = CGFloat(source.width) * scale
            let height = CGFloat(source.height) * scale
            UIImage(cgImage: source).draw(in: CGRect(x: (side - width) / 2,
                                                    y: (side - height) / 2,
                                                    width: width, height: height))
        }
        return MPMediaItemArtwork(boundsSize: bitmap.size) { requested in
            let width = min(side, max(1, requested.width))
            let height = min(side, max(1, requested.height))
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                           format: format).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let fittedSide = min(width, height)
                bitmap.draw(in: CGRect(x: (width - fittedSide) / 2,
                                       y: (height - fittedSide) / 2,
                                       width: fittedSide, height: fittedSide))
            }
        }
    }
}

/// Coalesces the cover used by the player, its background and the lock screen.
/// File IO, SD disk reads and ImageIO decompression stay off MainActor. The
/// bounded decoded cache is independent of permanent offline cover sidecars.
actor PlayerArtworkStore {
    static let shared = PlayerArtworkStore()
    typealias DataLoader = @Sendable (URL) async -> Data?
    private let decoded = NSCache<NSURL, UIImage>()
    private var dataTasks: [URL: Task<Data?, Never>] = [:]
    private var imageTasks: [URL: Task<UIImage?, Never>] = [:]
    private let loadData: DataLoader
    private var generation = 0

    init(loadData: @escaping DataLoader = PlayerArtworkStore.readData) {
        self.loadData = loadData
        decoded.totalCostLimit = 12 * 1_024 * 1_024
        decoded.countLimit = 6
    }

    func image(at url: URL) async -> UIImage? {
        if let cached = decoded.object(forKey: url as NSURL) { return cached }
        if let existing = imageTasks[url] { return await existing.value }
        let revision = generation
        let task = Task(priority: .utility) { () -> UIImage? in
            guard let bytes = await self.data(at: url), !Task.isCancelled else { return nil }
            return NowPlayingArtworkLoader.image(from: bytes)
        }
        imageTasks[url] = task
        let image = await task.value
        guard revision == generation else { return image }
        imageTasks[url] = nil
        if let image, let bitmap = image.cgImage {
            decoded.setObject(image, forKey: url as NSURL, cost: bitmap.bytesPerRow * bitmap.height)
        }
        return image
    }

    func data(at url: URL) async -> Data? {
        if let existing = dataTasks[url] { return await existing.value }
        let loader = loadData, revision = generation
        let task = Task.detached(priority: .utility) { await loader(url) }
        dataTasks[url] = task
        let data = await task.value
        if revision == generation { dataTasks[url] = nil }
        return data
    }

    func removeAll() {
        generation &+= 1
        decoded.removeAllObjects()
        dataTasks.values.forEach { $0.cancel() }
        imageTasks.values.forEach { $0.cancel() }
        dataTasks.removeAll(); imageTasks.removeAll()
    }

    nonisolated static func readData(at url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url, options: .mappedIfSafe) }
        guard url.scheme == "https" else { return nil }
        // Read original compressed bytes directly. imageFromCache + pngData
        // used to decode and re-encode a full cover on every player request.
        if let cached = SDImageCache.shared.diskImageData(forKey: url.absoluteString) { return cached }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
              bytes.count <= 6 * 1_024 * 1_024 else { return nil }
        return bytes
    }
}
