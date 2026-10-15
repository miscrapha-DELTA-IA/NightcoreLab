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
    let experienceID: String
    let material: VisualMaterial
    let reactionMode: CreativePreset.AudioReaction
    let sectionCadence: SongSectionCadence
    let typographyStyle: TypographyStyle
    let scoreStamp: KaraokePerformanceStamp?

    init(trackID: String, title: String, artist: String?, artworkURL: URL?,
         theme: AppTheme, visualStyle: VisualStyle, marblePhase: Float,
         timestamp: Date,
         experienceID: String = CreativePresetCatalog.defaultID,
         material: VisualMaterial = .legacyMarble,
         reactionMode: CreativePreset.AudioReaction = .off,
         sectionCadence: SongSectionCadence = .neutral,
         typographyStyle: TypographyStyle = .neon,
         scoreStamp: KaraokePerformanceStamp? = nil) {
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
        self.experienceID = experienceID
        self.material = material
        self.reactionMode = reactionMode
        self.sectionCadence = sectionCadence
        self.typographyStyle = typographyStyle
        self.scoreStamp = scoreStamp
    }
}

@MainActor
enum ShareSnapshotBuilder {
    static func make(track: TrackInfo, theme: AppTheme,
                     visualStyle: ShareSnapshot.VisualStyle,
                     marbleStartedAt: Date, speed: Double,
                     capturedAt: Date = .now,
                     experienceID: String = CreativePresetCatalog.defaultID,
                     material: VisualMaterial = .legacyMarble,
                     reactionMode: CreativePreset.AudioReaction = .off,
                     sectionCadence: SongSectionCadence = .neutral,
                     typographyStyle: TypographyStyle = .neon,
                     scoreStamp: KaraokePerformanceStamp? = nil) -> ShareSnapshot {
        ShareSnapshot(
            trackID: track.id, title: track.title, artist: track.artist,
            artworkURL: track.coverURL, theme: theme, visualStyle: visualStyle,
            marblePhase: Float(max(0, capturedAt.timeIntervalSince(marbleStartedAt)) * speed),
            timestamp: capturedAt, experienceID: experienceID,
            material: material, reactionMode: reactionMode,
            sectionCadence: sectionCadence, typographyStyle: typographyStyle,
            scoreStamp: scoreStamp
        )
    }
}
