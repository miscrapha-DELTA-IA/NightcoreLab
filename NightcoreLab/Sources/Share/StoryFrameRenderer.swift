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

    var layoutPolicy: CompositionLayoutPolicy {
        request.layoutPolicy ?? CompositionLayoutPolicy.resolve(
            profile: profile, mode: request.mode)
    }

    var logicalSize: CGSize { layoutPolicy.canvasSize }
    var isLegacyPortrait: Bool { layoutPolicy.isLegacyPortrait }
    var effectiveCropPolicy: ExportCropPolicy { layoutPolicy.cropPolicy }

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

    private var adaptiveScene: StorySceneView {
        StorySceneView(request: request, artwork: artwork, frame: frame,
                       visualTimeline: visualTimeline, visualRhythm: visualRhythm,
                       resolvedCompositionFrame: resolvedCompositionFrame,
                       layoutPolicy: layoutPolicy)
    }

    @ViewBuilder
    var body: some View {
        if isLegacyPortrait {
            // EXACT old layout, no additional ZStack or scaling.
            originalScene
        } else if effectiveCropPolicy == .safeAreaPreserving {
            adaptiveScene
        } else {
            // Explicit legacy fit/crop, preserving historical framing choices.
            ZStack {
                Color.black
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
        StoryMetalSurface.shared.beginFrame()
        let scene = StoryExportCanvas(request: request, artwork: artwork,
                                      frame: frame, profile: profile,
                                      visualTimeline: visualTimeline,
                                      visualRhythm: visualRhythm)
        let renderer = ImageRenderer(content: scene)
        renderer.proposedSize = ProposedViewSize(scene.logicalSize)
        renderer.scale = CGFloat(profile.width) / scene.logicalSize.width
        guard let image = renderer.uiImage?.cgImage,
              image.width == profile.width, image.height == profile.height
        else { throw StoryVideoError.renderFailed }
        if let error = StoryMetalSurface.shared.lastError { throw error }
        return image
    }
}
