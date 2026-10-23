import SwiftUI
import UIKit

/// Both player surfaces accept the same local sidecar URL. The associated URL
/// keeps a late image from a previous track out of the current player's view.
/// Transient image/CDN failures are retried while mounted, with the original
/// thumbnail always preferred to any backup.
struct PlayerArtworkImage<Content: View>: View {
    let url: URL?
    let fallbackURLs: [URL]
    @ViewBuilder var content: (Image?) -> Content
    @State private var loaded: Loaded?

    init(url: URL?, fallbackURLs: [URL] = [], @ViewBuilder content: @escaping (Image?) -> Content) {
        self.url = url
        self.fallbackURLs = fallbackURLs
        self.content = content
    }

    private struct Loaded {
        let url: URL
        let image: UIImage
    }

    private var candidates: [URL] {
        var seen = Set<URL>()
        return ([url].compactMap { $0 } + fallbackURLs)
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        let requestedURLs = candidates
        let identity = url ?? requestedURLs.first
        content(loaded.flatMap { $0.url == identity ? Image(uiImage: $0.image) : nil })
            .task(id: requestedURLs) {
                loaded = nil
                guard let identity else { return }
                // No permanent "logo" after a single timeout or loss of Wi-Fi.
                // The task cancels on track/view changes, so a stale cover cannot win.
                for attempt in 0..<3 {
                    for candidate in requestedURLs {
                        guard !Task.isCancelled else { return }
                        if let image = await NowPlayingArtworkLoader.coverImage(at: candidate) {
                            guard !Task.isCancelled else { return }
                            loaded = Loaded(url: identity, image: image)
                            return
                        }
                    }
                    guard attempt < 2 else { return }
                    do {
                        try await Task.sleep(for: .seconds(attempt == 0 ? 1.5 : 4))
                    } catch {
                        return
                    }
                }
            }
    }
}
