import Foundation

/// Narrow compatibility boundary to the EXISTING renderer. Does not draw,
/// create shaders, mutate a layer, or choose a new visual style.
enum ResolvedFrameRendererAdapter {
    /// The Metal Marble shader already consumes only reactiveDistortion.
    /// Keep all CreativeParameterFrame fields intact for future consumers.
    static func marbleParameters(from frame: ResolvedCompositionFrame?)
        -> CreativeParameterFrame {
        frame?.programParameters ?? .neutral
    }

    static func marbleDistortion(from frame: ResolvedCompositionFrame?) -> Double {
        frame?.materialFrame?.parameters.distortion ?? marbleParameters(from: frame).marbleDistortion
    }

    /// The actual StoryFrameRenderer remains unchanged. Both consumers call
    /// StorySceneView with the same frozen request and timestamp; its bridge
    /// resolves (or accepts) exactly one ResolvedCompositionFrame.
    static func matches(_ frame: ResolvedCompositionFrame,
                        composition: VisualComposition,
                        elapsed: TimeInterval) -> Bool {
        guard let timestamp = composition.timeline.timestamp(at: elapsed) else {
            return false
        }
        return frame.compositionID == composition.id &&
               frame.timestamp == timestamp &&
               frame.deterministicSeed == composition.deterministicSeed
    }
}
