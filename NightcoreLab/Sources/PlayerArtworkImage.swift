import SwiftUI
import UIKit

/// Both player surfaces accept the same local sidecar URL. The associated URL
/// keeps a late image from a previous track out of the current player's view.
struct PlayerArtworkImage<Content: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image?) -> Content
    @State private var loaded: Loaded?
    private struct Loaded {
        let url: URL
        let image: UIImage
    }

    var body: some View {
        content(loaded.flatMap { $0.url == url ? Image(uiImage: $0.image) : nil })
            .task(id: url) {
                guard let url else { loaded = nil; return }
                let image = await NowPlayingArtworkLoader.coverImage(at: url)
                guard !Task.isCancelled else { return }
                loaded = image.map { Loaded(url: url, image: $0) }
            }
    }
}
