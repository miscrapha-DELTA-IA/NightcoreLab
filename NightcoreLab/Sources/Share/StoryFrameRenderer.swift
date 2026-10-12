import CoreGraphics
import SwiftUI
import UIKit

/// One native SwiftUI/Metal scene renderer shared by export and frame
/// inspection. All ImageRenderer work stays on MainActor; encoding and pixel
/// buffer painting remain in StoryPixelWriter's worker actor.
@MainActor
enum StoryFrameRenderer {
    static func render(request: StoryVideoRequest, artwork: UIImage?,
                       frame: StoryRenderFrame,
                       profile: StoryEncodingProfile,
                       visualTimeline: AudioFeatureTimeline? = nil) throws -> CGImage {
        let scene = StorySceneView(request: request, artwork: artwork,
                                   frame: frame, visualTimeline: visualTimeline)
        let renderer = ImageRenderer(content: scene)
        renderer.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        renderer.scale = profile.scale
        guard let image = renderer.uiImage?.cgImage,
              image.width == profile.width, image.height == profile.height
        else { throw StoryVideoError.renderFailed }
        return image
    }
}
