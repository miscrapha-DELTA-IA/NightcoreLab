import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// A light-weight hue extracted from a 24x24 pixel version of the cover art.
/// Stores a value, not a decoded UIImage, so the karaoke view stays inexpensive.
struct ArtworkTint: Equatable, Sendable {
    let hue: Double

    var color: Color {
        Color(hue: hue, saturation: 0.84, brightness: 1.0)
    }
}

enum ArtworkTintExtractor {
    /// Run once per selected track, never inside the karaoke display timeline.
    static func fetch(for track: Track) async -> ArtworkTint? {
        // Prefer the artwork actually attached to the track; fall back to YouTube's
        // small cover rather than loading the full-resolution background twice.
        guard let url = track.thumbnailURL ??
                URL(string: "https://i.ytimg.com/vi/\(track.id)/hqdefault.jpg") else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 2 * 1024 * 1024 else { return nil }
            return await Task.detached(priority: .utility) {
                extract(from: data)
            }.value
        } catch {
            return nil // Use the current app theme if the artwork cannot be sampled.
        }
    }

    static func extract(from data: Data) -> ArtworkTint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let side = 24
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = rgba.withUnsafeMutableBytes { pixels -> Bool in
            guard let context = CGContext(
                data: pixels.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered, let hue = dominantHue(in: rgba) else { return nil }
        return ArtworkTint(hue: hue)
    }

    /// Samples vibrant pixels rather than averaging RGB into a muddy grey.
    /// Pure and deterministic, so it can be tested without a network or UIKit.
    static func dominantHue(in rgba: [UInt8]) -> Double? {
        guard rgba.count >= 4, rgba.count.isMultiple(of: 4) else { return nil }
        let bins = 18
        var weight = [Double](repeating: 0, count: bins)
        var x = [Double](repeating: 0, count: bins)
        var y = [Double](repeating: 0, count: bins)

        for offset in stride(from: 0, to: rgba.count, by: 4) {
            guard rgba[offset + 3] > 127 else { continue }
            let r = Double(rgba[offset]) / 255
            let g = Double(rgba[offset + 1]) / 255
            let b = Double(rgba[offset + 2]) / 255
            let high = max(r, g, b)
            let low = min(r, g, b)
            let chroma = high - low
            guard high >= 0.22, chroma >= 0.15 else { continue }
            let saturation = chroma / high
            guard saturation > 0.22 else { continue }

            let sextant: Double
            if high == r {
                sextant = (g - b) / chroma
            } else if high == g {
                sextant = (b - r) / chroma + 2
            } else {
                sextant = (r - g) / chroma + 4
            }
            let hue = ((sextant / 6).truncatingRemainder(dividingBy: 1) + 1)
                .truncatingRemainder(dividingBy: 1)
            let index = min(Int(hue * Double(bins)), bins - 1)
            let contribution = saturation * saturation * high
            weight[index] += contribution
            x[index] += contribution * cos(2 * Double.pi * hue)
            y[index] += contribution * sin(2 * Double.pi * hue)
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0.1 else { return nil }
        let angle = atan2(y[best], x[best]) / (2 * Double.pi)
        return (angle + 1).truncatingRemainder(dividingBy: 1)
    }
}
