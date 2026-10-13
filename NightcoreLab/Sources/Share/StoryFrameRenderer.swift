import CoreGraphics
import SwiftUI
import UIKit

/// The ONLY aspect-ratio adapter for scrub preview, stills and MP4.
/// Do not modify the authored 540x960 StorySceneView hierarchy. Non-portrait
/// content is fit within the destination; optional central crop is only for
/// player mode and is never applied to lyrics.
struct StoryExportCanvas: View {
    let request: StoryVideoRequest
    let artwork: UIImage?
    let frame: StoryRenderFrame
    let profile: StoryEncodingProfile
    var visualTimeline: AudioFeatureTimeline? = nil
    var visualRhythm: RhythmAnalysisResult? = nil
    var resolvedCompositionFrame: ResolvedCompositionFrame? = nil

    var logicalSize: CGSize {
        CGSize(width: StoryVideoRequest.size.width,
               height: StoryVideoRequest.size.width *
                   CGFloat(profile.height) / CGFloat(profile.width))
    }

    var isLegacyPortrait: Bool {
        profile.width * Int(StoryVideoRequest.size.height) ==
            profile.height * Int(StoryVideoRequest.size.width)
    }

    var effectiveCropPolicy: ExportCropPolicy {
        profile.cropPolicy.resolved(for: request.mode)
    }

    private var contentScale: CGFloat {
        let x = logicalSize.width / StoryVideoRequest.size.width
        let y = logicalSize.height / StoryVideoRequest.size.height
        return effectiveCropPolicy == .centerCrop ? max(x, y) : min(x, y)
    }

    private var originalScene: StorySceneView {
        StorySceneView(request: request, artwork: artwork, frame: frame,
                       visualTimeline: visualTimeline, visualRhythm: visualRhythm,
                       resolvedCompositionFrame: resolvedCompositionFrame)
    }

    @ViewBuilder
    var body: some View {
        if isLegacyPortrait {
            // EXACT old layout, no additional ZStack or scaling.
            originalScene
        } else {
            ZStack {
                Color.black
                if effectiveCropPolicy == .safeAreaPreserving {
                    request.theme.accent.opacity(0.12)
                }
                originalScene
                    .frame(width: StoryVideoRequest.size.width,
                           height: StoryVideoRequest.size.height)
                    .scaleEffect(contentScale)
            }
            .frame(width: logicalSize.width, height: logicalSize.height)
            .clipped()
        }
    }
}

/// Single native SwiftUI/Metal scene renderer shared by video export, frozen
/// scrub preview and thumbnail creation. H.264 encoding remains elsewhere.
@MainActor
enum StoryFrameRenderer {
    static func render(request: StoryVideoRequest, artwork: UIImage?,
                       frame: StoryRenderFrame,
                       profile: StoryEncodingProfile,
                       visualTimeline: AudioFeatureTimeline? = nil,
                       visualRhythm: RhythmAnalysisResult? = nil) throws -> CGImage {
        let scene = StoryExportCanvas(request: request, artwork: artwork,
                                      frame: frame, profile: profile,
                                      visualTimeline: visualTimeline,
                                      visualRhythm: visualRhythm)
        let renderer = ImageRenderer(content: scene)
        renderer.proposedSize = ProposedViewSize(scene.logicalSize)
        renderer.scale = profile.scale
        guard let image = renderer.uiImage?.cgImage,
              image.width == profile.width, image.height == profile.height
        else { throw StoryVideoError.renderFailed }
        return image
    }
}
