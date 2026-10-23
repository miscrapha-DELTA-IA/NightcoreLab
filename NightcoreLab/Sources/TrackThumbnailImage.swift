import SDWebImageSwiftUI
import SwiftUI

/// Original-first thumbnails for search, queue and discovery. Local offline
/// artwork wins when present; a provider URL and stable YouTube URL follow.
struct TrackThumbnailImage: View {
    let track: Track
    var localArtworkURL: URL? = nil
    @State private var candidateIndex = 0

    private var candidates: [URL] {
        var seen = Set<URL>()
        return ([localArtworkURL].compactMap { $0 } + track.artworkCandidateURLs)
            .filter { seen.insert($0).inserted }
    }
    private var selectedURL: URL? {
        candidates.indices.contains(candidateIndex)
            ? candidates[candidateIndex] : candidates.first
    }

    var body: some View {
        WebImage(url: selectedURL, options: [.retryFailed])
            .onFailure { _ in
                let nextIndex = candidateIndex + 1
                guard nextIndex < candidates.count else { return }
                Task { @MainActor in
                    // A stale failure from a previous source may not overwrite
                    // the current track's fallback decision.
                    guard candidateIndex < nextIndex else { return }
                    candidateIndex = nextIndex
                }
            }
            .resizable()
            .id(selectedURL)
            .onChange(of: candidates) { _, _ in
                candidateIndex = 0
            }
    }
}
