import Foundation

struct Track: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let thumbnailURL: URL?
    var isCached = false

    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

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
