import SDWebImageSwiftUI
import SwiftUI

/// A compact, cache-backed list thumbnail. Keep the provider artwork as first
/// choice. SDWebImage normally blocks a failed URL for this session; retryFailed
/// allows a later attempt, and a stable YouTube backup covers expired CDN URLs.
struct TrackThumbnailImage: View {
    let track: Track
    @State private var usingBackup = false

    private var candidates: [URL] { track.artworkCandidateURLs }
    private var selectedURL: URL? {
        usingBackup ? candidates.last : candidates.first
    }

    var body: some View {
        WebImage(url: selectedURL, options: [.retryFailed])
            .onFailure { _ in
                guard !usingBackup, candidates.count > 1 else { return }
                Task { @MainActor in
                    usingBackup = true
                }
            }
            .resizable()
            .id(selectedURL)
            .onChange(of: candidates) { _, _ in
                usingBackup = false
            }
    }
}
