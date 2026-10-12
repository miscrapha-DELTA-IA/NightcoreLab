import AVFoundation
import SwiftUI

/// All export inputs are frozen *before* the preview is opened.
struct StoryVideoDraft: Identifiable {
    let id = UUID()
    let request: StoryVideoRequest
    let audioSource: StoryAudioSource?
    let profile: StoryEncodingProfile
    let featureEngine: AudioFeatureEngine
}

/// Visual proofing before the expensive MP4 export. This displays the same
/// StorySceneView at an exact integer frame as StoryFrameRenderer, using the
/// same cached artwork and immutable request. It intentionally does not play
/// audio or install any TimelineView.
struct StoryDraftPreview: View {
    let draft: StoryVideoDraft
    let onExport: (UIImage?, AudioFeatureTimeline?) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork: UIImage?
    @State private var artworkIsLoaded = false
    @State private var visualTimeline: AudioFeatureTimeline?
    @State private var visualIsReady = false
    @State private var elapsed: TimeInterval = 0

    private var timeline: StoryRenderTimeline {
        StoryRenderTimeline(request: draft.request, profile: draft.profile)
    }

    private var currentFrame: StoryRenderFrame { timeline.frame(at: elapsed) }

    /// Explicit preview-side request; export uses the identical runtime from
    /// StorySceneView via the same frozen request and frame grid.
    private var compositionFrame: ResolvedCompositionFrame? {
        guard let composition = draft.request.visualComposition else { return nil }
        let typography = TypographyLayer.forStory(
            lines: draft.request.lines, lyricTime: currentFrame.lyricTime,
            lyricOffset: draft.request.lyricOffset)
        return CompositionRuntime(composition: composition).frame(
            at: currentFrame.elapsed, audioTimeline: visualTimeline,
            typography: typography)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 13) {
                GeometryReader { proxy in
                    let original = StoryVideoRequest.size
                    let scale = min(proxy.size.width / original.width,
                                    proxy.size.height / original.height)
                    StorySceneView(request: draft.request, artwork: artwork,
                                   frame: currentFrame,
                                   visualTimeline: visualTimeline,
                                   resolvedCompositionFrame: compositionFrame)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: original.width * scale,
                               height: original.height * scale,
                               alignment: .topLeading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .accessibilityLabel("Prévia do Story no tempo \(Int(currentFrame.elapsed)) segundos")
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if !artworkIsLoaded {
                        ProgressView("Carregando capa")
                            .padding(12)
                            .background(.regularMaterial, in: Capsule())
                    }
                }

                VStack(spacing: 4) {
                    Slider(value: $elapsed, in: 0...max(0.05, timeline.lastFrameElapsed),
                           step: 1 / Double(draft.profile.fps))
                        .tint(draft.request.theme.accent)
                        .accessibilityLabel("Navegar pelos quadros da prévia")
                    HStack {
                        Text(String(format: "%.2f s", currentFrame.elapsed))
                        Spacer()
                        Text("\(currentFrame.index + 1) / \(timeline.frameCount) frames")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Button {
                    onExport(artwork, visualTimeline)
                } label: {
                    Label("Gerar vídeo MP4", systemImage: "film")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!artworkIsLoaded || !visualIsReady)

                if !visualIsReady {
                    ProgressView("Analisando áudio para o Marble")
                        .font(.caption)
                }

                Text("Prévia visual sem áudio. O MP4 usará o mesmo Marble reativo, capa, preset e timestamps.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Prévia do Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar", action: onCancel)
                }
            }
            .task(id: draft.id) {
                let loaded = await ShareRenderer.loadArtwork(draft.request.artworkURL)
                guard !Task.isCancelled else { return }
                artwork = loaded
                artworkIsLoaded = true
            }
            .task(id: draft.id) {
                guard draft.request.reactiveProgram != nil,
                      let url = draft.request.reactiveSourceURL else {
                    visualIsReady = true
                    return
                }
                // A separate subscription shares identity/FFT/cache work with the
                // live reader, while cancellation affects only this preview.
                let result = try? await draft.featureEngine.analysisTimeline(for: url)
                guard !Task.isCancelled else { return }
                visualTimeline = result
                visualIsReady = true
            }
        }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .preferredColorScheme(.dark)
    }
}
