import AVFoundation
import SwiftUI

/// All audio/export inputs are frozen before the editor opens.
struct StoryVideoDraft: Identifiable {
    let id = UUID()
    let request: StoryVideoRequest
    let audioSource: StoryAudioSource?
    let profile: StoryEncodingProfile
    let featureEngine: AudioFeatureEngine
}

/// Stage 14B+15A editor. A preset/format/control edit freezes a new session;
/// scrubbing only samples the existing StoryRenderTimeline and runtime.
struct StoryDraftPreview: View {
    let draft: StoryVideoDraft
    let onExport: (CreatorPreset, StoryVideoRequest, UIImage?,
                   AudioFeatureTimeline?, RhythmAnalysisResult?) -> Void
    let onCancel: () -> Void

    @State private var selectedAspect: ExportAspectRatio
    @State private var selectedQuality: ExportQuality
    @State private var selectedCrop: ExportCropPolicy
    @State private var selectedExperienceID: String
    @State private var selectedMaterialID: String
    @State private var selectedTypography: TypographyStyle
    @State private var selectedTypographyPreset: TypographyPreset
    @State private var controls: CreatorControls
    @State private var frozenRequest: StoryVideoRequest
    @State private var frozenTimeline: StoryRenderTimeline
    @State private var presetSaveMessage: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork: UIImage?
    @State private var artworkIsLoaded = false
    @State private var visualTimeline: AudioFeatureTimeline?
    @State private var visualRhythm: RhythmAnalysisResult?
    @State private var visualIsReady = false
    @State private var elapsed: TimeInterval = 0
    @State private var showsScoreStamp: Bool

    init(draft: StoryVideoDraft,
         onExport: @escaping (CreatorPreset, StoryVideoRequest, UIImage?,
                              AudioFeatureTimeline?, RhythmAnalysisResult?) -> Void,
         onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onExport = onExport
        self.onCancel = onCancel

        let current = CreatorPreset(
            experienceID: draft.request.renderRuntime?.composition.program.id ??
                CreativePresetCatalog.defaultID,
            materialID: draft.request.renderRuntime?.material.id ??
                VisualMaterial.legacyMarble.id,
            typography: draft.request.typographyPreset,
            exportProfile: ExportProfile.matching(draft.profile))
        let initial = current
        let frozen = initial.applying(to: draft.request)
        _showsScoreStamp = State(initialValue: draft.request.showsScoreStamp)
        _selectedAspect = State(initialValue: initial.exportProfile.aspectRatio)
        _selectedQuality = State(initialValue: initial.exportProfile.quality)
        _selectedCrop = State(initialValue: initial.exportProfile.cropPolicy)
        _selectedExperienceID = State(initialValue: initial.experienceID)
        _selectedMaterialID = State(initialValue: initial.materialID)
        _selectedTypography = State(initialValue: initial.typography.style)
        _selectedTypographyPreset = State(initialValue: initial.typography)
        _controls = State(initialValue: initial.controls)
        _frozenRequest = State(initialValue: frozen)
        _frozenTimeline = State(initialValue: StoryRenderTimeline(
            request: frozen, profile: initial.exportProfile.encodingProfile(for: frozen.mode)))
    }

    private var selectedProfile: ExportProfile {
        ExportProfile(aspectRatio: selectedAspect, quality: selectedQuality,
                      cropPolicy: selectedCrop)
    }

    private var selectedPreset: CreatorPreset {
        CreatorPreset(experienceID: selectedExperienceID,
                      materialID: selectedMaterialID,
                      typography: selectedTypographyPreset,
                      controls: controls, exportProfile: selectedProfile)
    }

    private var encodingProfile: StoryEncodingProfile {
        selectedProfile.encodingProfile(for: frozenRequest.mode)
    }

    private var currentFrame: StoryRenderFrame {
        frozenTimeline.frame(at: elapsed)
    }

    private var compositionFrame: ResolvedCompositionFrame? {
        frozenRequest.resolvedFrame(currentFrame,
                                    audioTimeline: visualTimeline, rhythm: visualRhythm)
    }

    private func freezeSession(_ preset: CreatorPreset) {
        // Expensive composition compilation only when experience/material
        // identity changes; slider edits update the cheap typed mapping.
        var resolved = preset.applying(to: frozenRequest)
        resolved.showsScoreStamp = showsScoreStamp
        frozenRequest = resolved
        frozenTimeline = StoryRenderTimeline(
            request: resolved, profile: preset.exportProfile.encodingProfile(for: resolved.mode))
        elapsed = min(elapsed, frozenTimeline.lastFrameElapsed)
        presetSaveMessage = nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 13) {
                    HStack {
                        NightcoreBrandLockup(theme: frozenRequest.theme,
                                             iconSize: 25, titleSize: 18)
                        Spacer()
                    }
                    TrackIdentityPill(title: frozenRequest.title,
                                      artist: frozenRequest.artist,
                                      artwork: artwork, thumbnailSize: 40)
                        .accessibilityIdentifier("share.trackHeader")
                    GeometryReader { proxy in
                        let canvas = StoryExportCanvas(
                            request: frozenRequest, artwork: artwork,
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
                    .aspectRatio(CGFloat(encodingProfile.width) /
                                 CGFloat(encodingProfile.height), contentMode: .fit)
                    .frame(maxHeight: 450)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if !artworkIsLoaded {
                            ProgressView("Carregando capa")
                                .padding(12)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }

                    HStack(spacing: 10) {
                        Picker("Experiência", selection: $selectedExperienceID) {
                            ForEach(CreativePresetCatalog.all, id: \.id) { recipe in
                                Text(recipe.preset.name).tag(recipe.id)
                            }
                            ForEach(CreativePresetCatalog.selectableExperiences) { experience in
                                Text(experience.name).tag(experience.id)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Formato", selection: $selectedAspect) {
                            ForEach(ExportAspectRatio.allCases) { ratio in
                                Text(ratio.label).tag(ratio)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack(spacing: 10) {
                        Picker("Material", selection: $selectedMaterialID) {
                            ForEach(VisualMaterialCatalog.all) { material in
                                Text(material.name).tag(material.id)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Tipografia", selection: $selectedTypography) {
                            ForEach(TypographyStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack(spacing: 10) {
                        Picker("Qualidade", selection: $selectedQuality) {
                            ForEach(ExportQuality.allCases) { quality in
                                Text(quality.label).tag(quality)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Enquadramento", selection: $selectedCrop) {
                            ForEach(ExportCropPolicy.allCases) { policy in
                                if policy != .centerCrop || frozenRequest.mode == .player {
                                    Text(policy.label).tag(policy)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    DisclosureGroup("Creator Controls") {
                        VStack(spacing: 12) {
                            ForEach(CreatorControl.allCases) { control in
                                VStack(spacing: 4) {
                                    HStack {
                                        Text(control.label)
                                        Spacer()
                                        Text("\(Int(controls.value(for: control) * 100))%")
                                            .monospacedDigit()
                                    }
                                    .font(.caption)
                                    Slider(value: Binding(
                                        get: { controls.value(for: control) },
                                        set: { controls.set($0, for: control) }),
                                        in: 0...1, step: 0.01)
                                        .accessibilityLabel(control.label)
                                }
                            }
                            Button("Redefinir controles") { controls = .neutral }
                                .font(.caption)
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                    if frozenRequest.scoreStamp != nil {
                        Toggle("Mostrar nota do karaokê no Story", isOn: $showsScoreStamp)
                            .tint(draft.request.theme.accent)
                    }

                    Slider(value: $elapsed,
                           in: 0...max(0.05, frozenTimeline.lastFrameElapsed),
                           step: 1 / Double(encodingProfile.fps))
                        .tint(draft.request.theme.accent)
                        .accessibilityLabel("Navegar pelos quadros da prévia")
                    HStack {
                        Text(String(format: "%.2f s", currentFrame.elapsed))
                        Spacer()
                        Text("\(currentFrame.index + 1) / \(frozenTimeline.frameCount) frames")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    HStack {
                        Button("Salvar CreatorPreset") {
                            do {
                                try CreatorPresetStore.save(selectedPreset)
                                presetSaveMessage = "Preset salvo neste dispositivo"
                            } catch {
                                presetSaveMessage = "Não foi possível salvar o preset"
                            }
                        }
                        .buttonStyle(.bordered)

                        Button {
                            onExport(selectedPreset, frozenRequest, artwork,
                                     visualTimeline, visualRhythm)
                        } label: {
                            Label("Gerar MP4", systemImage: "film")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!artworkIsLoaded || !visualIsReady)
                    }
                    if let presetSaveMessage {
                        Text(presetSaveMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !visualIsReady {
                        ProgressView("Analisando áudio para o Marble")
                            .font(.caption)
                    }
                    Text("Prévia sem áudio. O canvas, os parâmetros criativos e os frames são os mesmos do MP4 e da thumbnail.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Creator Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar", action: onCancel)
                }
            }
            .onChange(of: selectedExperienceID) { _, selection in
                selectedMaterialID = CreativePresetCatalog.material(selection: selection).id
                let style = CreativePresetCatalog.typographyStyle(
                    afterSelecting: selection, current: selectedTypography)
                selectedTypography = style
                selectedTypographyPreset = CreativePresetCatalog.typographyPreset(
                    selection: selection, style: style,
                    font: draft.request.typographyPreset.font,
                    reacts: draft.request.reactionMode != .off)
            }
            .onChange(of: selectedTypography) { _, style in
                selectedTypographyPreset = CreativePresetCatalog.typographyPreset(
                    selection: selectedExperienceID, style: style,
                    font: draft.request.typographyPreset.font,
                    reacts: draft.request.reactionMode != .off)
            }
            .onChange(of: selectedPreset) { _, preset in
                freezeSession(preset)
            }
            .onChange(of: showsScoreStamp) { _, show in
                frozenRequest.showsScoreStamp = show
                frozenTimeline = StoryRenderTimeline(request: frozenRequest,
                    profile: encodingProfile)
            }
            .task(id: draft.id) {
                let loaded = await ShareRenderer.loadArtwork(draft.request.artworkURL)
                guard !Task.isCancelled else { return }
                artwork = loaded
                artworkIsLoaded = true
            }
            .task(id: draft.id) {
                guard draft.request.reactionMode != .off,
                      let url = draft.request.reactiveSourceURL else {
                    visualIsReady = true
                    return
                }
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
