import Foundation
import ImageIO
import SwiftUI
import UIKit

enum ShareRenderError: LocalizedError {
    case unableToRender

    var errorDescription: String? {
        switch self {
        case .unableToRender: return "Não foi possível renderizar o cartão."
        }
    }
}

@MainActor
enum ShareRenderer {
    /// The card is built once, on demand. No audio engine or playback state is mutated.
    static func render(_ snapshot: ShareSnapshot) async throws -> UIImage {
        let artwork = await loadArtwork(snapshot.artworkURL)
        try Task.checkCancellation()
        let renderer = ImageRenderer(content: ShareCardView(snapshot: snapshot, artwork: artwork))
        renderer.proposedSize = ProposedViewSize(ShareCardView.size)
        renderer.scale = 2 // 540×960 pt -> 1080×1920 px.
        guard let image = renderer.uiImage else {
            throw ShareRenderError.unableToRender
        }
        return image
    }

    /// Limit network bytes and downsample before decoding into a full-sized bitmap.
    static func loadArtwork(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        let data: Data
        do {
            if url.isFileURL {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } else {
                guard url.scheme == "https" else { return nil }
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad,
                                         timeoutInterval: 8)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (received, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                data = received
            }
        } catch {
            return nil
        }
        guard data.count <= 5 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let settings: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, settings as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
