import Foundation

struct Track: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let thumbnailURL: URL?
    var isCached = false

    // Populados por resultados estruturados do YT Music; opcionais para links,
    // playlists e sessões salvas de versões anteriores.
    var cleanArtist: String? = nil
    var cleanTitle: String? = nil
    var album: String? = nil
    var duration: TimeInterval? = nil
    /// Optional ID3 track number; old cached records decode without this field.
    var trackNumber: Int? = nil

    var catalogProvider: String? = nil
    var collectionID: String? = nil
    var artistID: String? = nil
    var streamVideoID: String? = nil

    /// Never replace provider artwork when it works. For YouTube tracks only,
    /// keep a stable video thumbnail as backup when a signed/expiring URL fails.
    var artworkCandidateURLs: [URL] {
        var candidates: [URL] = []
        if let thumbnailURL, thumbnailURL.scheme?.lowercased() == "https" || thumbnailURL.isFileURL {
            candidates.append(thumbnailURL)
        }
        let videoID = streamVideoID ?? id
        if videoID.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil,
           let fallback = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
           !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }

    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(streamVideoID ?? id)")! }

    static func from(url: String) -> Track? {
        guard let canonical = AudioDownloadManager.youtubeVideoURL(from: url),
              let id = URLComponents(url: canonical, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        return Track(id: id, title: id,
                     thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"))
    }
}

/// Wire format of the existing /related endpoint.
struct RelatedVideo: Decodable {
    let title: String
    let thumbnail: URL?
    let url: URL
}
