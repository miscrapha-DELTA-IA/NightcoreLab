import Foundation

/// Immutable read of everything needed to share, captured at a single instant.
struct ShareSnapshot: Sendable, Equatable {
    enum VisualStyle: Sendable, Equatable {
        case marble
        case blurredArtwork
    }

    let trackID: String
    let title: String
    let artist: String?
    let artworkURL: URL?
    let theme: AppTheme
    let visualStyle: VisualStyle
    let marblePhase: Float
    let timestamp: Date

    init(trackID: String, title: String, artist: String?, artworkURL: URL?,
         theme: AppTheme, visualStyle: VisualStyle, marblePhase: Float,
         timestamp: Date) {
        self.trackID = trackID
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle.isEmpty ? "Música sem título" : trimmedTitle
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = trimmedArtist?.isEmpty == false ? trimmedArtist : nil
        self.artworkURL = artworkURL
        self.theme = theme
        self.visualStyle = visualStyle
        self.marblePhase = max(0, marblePhase)
        self.timestamp = timestamp
    }
}

@MainActor
enum ShareSnapshotBuilder {
    static func make(track: TrackInfo, theme: AppTheme,
                     visualStyle: ShareSnapshot.VisualStyle,
                     marbleStartedAt: Date, speed: Double,
                     capturedAt: Date = .now) -> ShareSnapshot {
        ShareSnapshot(
            trackID: track.id, title: track.title, artist: track.artist,
            artworkURL: track.coverURL, theme: theme, visualStyle: visualStyle,
            marblePhase: Float(max(0, capturedAt.timeIntervalSince(marbleStartedAt)) * speed),
            timestamp: capturedAt
        )
    }
}
