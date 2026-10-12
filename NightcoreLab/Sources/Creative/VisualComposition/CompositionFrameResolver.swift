import Foundation

/// Source-compatible entry point for existing call sites. Clients rendering
/// many frames should retain a CompositionRuntime to reuse compiled tracks.
enum CompositionFrameResolver {
    static func resolve(_ composition: VisualComposition,
                        elapsed: TimeInterval,
                        features: AudioFeatures? = nil) -> ResolvedCompositionFrame? {
        CompositionRuntime(composition: composition)
            .frame(at: elapsed, features: features)
    }
}
