import CoreGraphics
import Foundation

/// A session-frozen geometry contract. The timeline, typography effects and
/// MaterialResolver remain independent of orientation and pixel resolution.
struct CompositionLayoutPolicy: Equatable, Sendable {
    let aspectRatio: ExportAspectRatio
    let canvas: CGRect
    let safeArea: CGRect
    let titleArea: CGRect
    let mainArea: CGRect
    let lyricsArea: CGRect
    let footerArea: CGRect
    let materialViewport: CGRect
    let cropPolicy: ExportCropPolicy
    let artworkSide: CGFloat
    let lyricFontSize: CGFloat
    let neighboringLyricFontSize: CGFloat

    var isLegacyPortrait: Bool { aspectRatio == .portrait }
    var canvasSize: CGSize { canvas.size }
    var materialAspectRatio: CGFloat { materialViewport.width / materialViewport.height }

    /// Resolve once when an export format is selected. Geometry uses points,
    /// not output pixels, so quality changes do not reflow the composition.
    static func resolve(profile: StoryEncodingProfile, mode: StoryMode) -> Self {
        let policy = profile.cropPolicy.resolved(for: mode)
        if profile.width * 16 == profile.height * 9 {
            let canvas = CGRect(x: 0, y: 0, width: 540, height: 960)
            return Self(
                aspectRatio: .portrait, canvas: canvas,
                safeArea: CGRect(x: 35, y: 50, width: 470, height: 864),
                titleArea: CGRect(x: 35, y: 50, width: 470, height: 40),
                mainArea: CGRect(x: 35, y: 125, width: 470, height: 740),
                lyricsArea: CGRect(x: 50, y: 215, width: 440, height: 535),
                footerArea: CGRect(x: 35, y: 870, width: 470, height: 44),
                materialViewport: canvas, cropPolicy: policy,
                artworkSide: 230, lyricFontSize: 35,
                neighboringLyricFontSize: 23)
        }
        if profile.width == profile.height {
            let canvas = CGRect(x: 0, y: 0, width: 540, height: 540)
            return Self(
                aspectRatio: .square, canvas: canvas,
                safeArea: CGRect(x: 24, y: 24, width: 492, height: 492),
                titleArea: CGRect(x: 30, y: 18, width: 480, height: 44),
                mainArea: CGRect(x: 60, y: 76, width: 420, height: 385),
                lyricsArea: CGRect(x: 48, y: 116, width: 444, height: 310),
                footerArea: CGRect(x: 30, y: 485, width: 480, height: 35),
                materialViewport: canvas, cropPolicy: policy,
                artworkSide: 150, lyricFontSize: 29,
                neighboringLyricFontSize: 18)
        }
        // All non-square, non-portrait ExportProfile targets are 16:9.
        let canvas = CGRect(x: 0, y: 0, width: 960, height: 540)
        return Self(
            aspectRatio: .landscape, canvas: canvas,
            safeArea: CGRect(x: 36, y: 24, width: 888, height: 492),
            titleArea: CGRect(x: 40, y: 20, width: 880, height: 43),
            mainArea: CGRect(x: 208, y: 75, width: 544, height: 394),
            lyricsArea: CGRect(x: 110, y: 130, width: 740, height: 270),
            footerArea: CGRect(x: 40, y: 486, width: 880, height: 34),
            materialViewport: canvas, cropPolicy: policy,
            artworkSide: 190, lyricFontSize: 35,
            neighboringLyricFontSize: 21)
    }
}
