import AVFoundation
import CoreImage
import Foundation
import ImageIO
import MediaPlayer
import UIKit

/// Produces a bitmap-backed artwork image for the system player. This is kept
/// separate from Share rendering and never changes the on-screen cover.
@MainActor
enum NowPlayingArtworkLoader {
    static func officialLogo() -> MPMediaItemArtwork? {
        UIImage(named: "NightcoreLogo").flatMap(artwork)
    }

    static func load(coverURL: URL?, mediaURL: URL?) async -> MPMediaItemArtwork? {
        if let coverURL, let data = await coverData(at: coverURL),
           !Task.isCancelled, let image = image(from: data),
           let cover = artwork(image) { return cover }
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

    private static func coverData(at coverURL: URL) async -> Data? {
        let data: Data?
        if coverURL.isFileURL {
            data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: coverURL, options: .mappedIfSafe)
            }.value
        } else if coverURL.scheme == "https" {
            var request = URLRequest(url: coverURL, cachePolicy: .returnCacheDataElseLoad,
                                     timeoutInterval: 8)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            if let (received, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                data = received
            } else { data = nil }
        } else { data = nil }
        return data
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

    private static func image(from data: Data) -> UIImage? {
        guard data.count <= 6 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024
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
