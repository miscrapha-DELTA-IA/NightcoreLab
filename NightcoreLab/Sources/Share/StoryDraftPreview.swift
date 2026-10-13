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
    let onExport: (ExportProfile, UIImage?, AudioFeatureTimeline?, RhythmAnalysisResult?) -> Void
    let onCancel: () -> Void

    @State private var selectedAspect: ExportAspectRatio = .portrait
    @State private var selectedQuality: ExportQuality
    @State private var selectedCrop: ExportCropPolicy = .safeAreaPreserving

    init(draft: StoryVideoDraft,
         onExport: @escaping (ExportProfile, UIImage?, AudioFeatureTimeline?,
                              RhythmAnalysisResult?) -> Void,
         onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onExport = onExport
        self.onCancel = onCancel
        _selectedQuality = State(initialValue: ExportProfile.matching(draft.profile).quality)
    }

    private var selectedProfile: ExportProfile {
        ExportProfile(aspectRatio: selectedAspect, quality: selectedQuality,
                      cropPolicy: selectedCrop)
    }

    private var encodingProfile: StoryEncodingProfile {
        selectedProfile.encodingProfile(for: draft.request.mode)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork: UIImage?
    @State private var artworkIsLoaded = false
    @State private var visualTimeline: AudioFeatureTimeline?
    @State private var visualRhythm: RhythmAnalysisResult?
    @State private var visualIsReady = false
    @State private var elapsed: TimeInterval = 0

    private var timeline: StoryRenderTimeline {
        StoryRenderTimeline(request: draft.request, profile: encodingProfile)
    }

    private var currentFrame: StoryRenderFrame { timeline.frame(at: elapsed) }

    /// Explicit preview-side request; export uses the identical runtime from
    /// StorySceneView via the same frozen request and frame grid.
    private var compositionFrame: ResolvedCompositionFrame? {
        // Same function and inputs as the exporter (StorySceneView).
        draft.request.resolvedFrame(currentFrame, audioTimeline: visualTimeline,
                                    rhythm: visualRhythm)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 13) {
                GeometryReader { proxy in
                    let canvas = StoryExportCanvas(
                        request: draft.request, artwork: artwork,
                        frame: currentFrame, profile: encodingProfile,
                        visualTimeline: visualTimeline, visualRhythm: visualRhythm,
                        resolvedCompositionFrame: compositionFrame)
                    let size = canvas.logicalSize
                    let scale = min(proxy.size.width / size.width,
                                    proxy.size.height / size.height)
                    canvas
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: size.width * scale,
                               height: size.height * scale,
                               alignment: .topLeading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .accessibilityLabel("Prévia do Story no tempo \(Int(currentFrame.elapsed)) segundos")
                }
                .aspectRatio(CGFloat(encodingProfile.width) / CGFloat(encodingProfile.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if !artworkIsLoaded {
                        ProgressView("Carregando capa")
                            .padding(12)
                            .background(.regularMaterial, in: Capsule())
                    }
                }

                HStack(spacing: 10) {
                    Picker("Formato", selection: $selectedAspect) {
                        ForEach(ExportAspectRatio.allCases) { ratio in
                            Text(ratio.label).tag(ratio)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Qualidade", selection: $selectedQuality) {
                        ForEach(ExportQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .frame(maxWidth: .infinity)

                Picker("Enquadramento", selection: $selectedCrop) {
                    ForEach(ExportCropPolicy.allCases) { policy in
                        if policy != .centerCrop || draft.request.mode == .player {
                            Text(policy.label).tag(policy)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 4) {
                    Slider(value: $elapsed, in: 0...max(0.05, timeline.lastFrameElapsed),
                           step: 1 / Double(encodingProfile.fps))
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
                    onExport(selectedProfile, artwork, visualTimeline, visualRhythm)
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

                Text("Prévia sem áudio. O MP4, a thumbnail e esta prévia usam o mesmo frame e enquadramento. Cortes centrais podem ocultar elementos do player.")
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
                // Energy timeline AND rhythm (Marble beat pulse) in one request.
                let result = try? await draft.featureEngine.analysisResult(for: url)
                guard !Task.isCancelled else { return }
                visualTimeline = result?.energyTimeline
                visualRhythm = result?.rhythmAnalysis
                visualIsReady = true
            }
        }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .preferredColorScheme(.dark)
    }
}
