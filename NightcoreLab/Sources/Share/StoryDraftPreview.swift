import AVFoundation
import SwiftUI

/// Frozen inputs shared by the preview, PNG image and MP4 encoder.
struct StoryVideoDraft: Identifiable {
    let id = UUID()
    let request: StoryVideoRequest
    let audioSource: StoryAudioSource?
    let profile: StoryEncodingProfile
    let featureEngine: AudioFeatureEngine
}

/// One single-screen export customizer. Creator parameters remain in the actual
/// Criar workspace; the Share screen is intentionally limited to clear choices.
struct StoryDraftPreview: View {
    let draft: StoryVideoDraft
    let onExport: (CreatorPreset, StoryVideoRequest, UIImage?,
                   AudioFeatureTimeline?, RhythmAnalysisResult?) -> Void
    let onSaveImage: ((UIImage) -> Void)?
    let onCancel: () -> Void

    @State private var selectedAspect: ExportAspectRatio
    @State private var selectedQuality: ExportQuality
    @State private var selectedCrop: ExportCropPolicy
    @State private var selectedExperienceID: String
    @State private var selectedMaterialID: String
    @State private var selectedTypography: TypographyStyle
    @State private var selectedTypographyPreset: TypographyPreset
    @State private var selectedReaction: CreativePreset.AudioReaction
    @State private var selectedTheme: AppTheme
    @State private var controls: CreatorControls
    @State private var frozenRequest: StoryVideoRequest
    @State private var frozenTimeline: StoryRenderTimeline
    @State private var artwork: UIImage?
    @State private var artworkIsLoaded = false
    @State private var visualTimeline: AudioFeatureTimeline?
    @State private var visualRhythm: RhythmAnalysisResult?
    @State private var visualIsReady = true
    @State private var elapsed: TimeInterval = 0
    @State private var showsScoreStamp: Bool
    @State private var showsTrackCard: Bool
    @State private var showsBrand: Bool
    @State private var showsLyrics: Bool
    @State private var renderingImage = false
    @State private var imageError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(draft: StoryVideoDraft,
         onExport: @escaping (CreatorPreset, StoryVideoRequest, UIImage?,
                              AudioFeatureTimeline?, RhythmAnalysisResult?) -> Void,
         onSaveImage: ((UIImage) -> Void)? = nil,
         onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onExport = onExport
        self.onSaveImage = onSaveImage
        self.onCancel = onCancel
        let initial = CreatorPreset(
            experienceID: draft.request.renderRuntime?.composition.program.id ??
                CreativePresetCatalog.defaultID,
            materialID: draft.request.renderRuntime?.material.id ??
                VisualMaterial.legacyMarble.id,
            typography: draft.request.typographyPreset,
            exportProfile: ExportProfile.matching(draft.profile))
        var frozen = initial.applying(to: draft.request)
        frozen.reactionMode = .off // Calm, clean export is the default.
        _selectedAspect = State(initialValue: initial.exportProfile.aspectRatio)
        _selectedQuality = State(initialValue: initial.exportProfile.quality)
        _selectedCrop = State(initialValue: initial.exportProfile.cropPolicy)
        _selectedExperienceID = State(initialValue: initial.experienceID)
        _selectedMaterialID = State(initialValue: initial.materialID)
        _selectedTypography = State(initialValue: initial.typography.style)
        _selectedTypographyPreset = State(initialValue: initial.typography)
        _selectedReaction = State(initialValue: .off)
        _selectedTheme = State(initialValue: draft.request.theme)
        _controls = State(initialValue: initial.controls)
        _showsScoreStamp = State(initialValue: draft.request.showsScoreStamp)
        _showsTrackCard = State(initialValue: draft.request.showsTrackCard)
        _showsBrand = State(initialValue: draft.request.showsBrand)
        _showsLyrics = State(initialValue: draft.request.showsLyrics)
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
    private var currentFrame: StoryRenderFrame { frozenTimeline.frame(at: elapsed) }
    private var compositionFrame: ResolvedCompositionFrame? {
        frozenRequest.resolvedFrame(currentFrame,
            audioTimeline: visualTimeline, rhythm: visualRhythm)
    }

    private func freezeSession(_ preset: CreatorPreset) {
        var candidate = frozenRequest
        candidate.theme = selectedTheme
        candidate.reactionMode = selectedReaction
        candidate.showsScoreStamp = showsScoreStamp
        candidate.showsTrackCard = showsTrackCard
        candidate.showsBrand = showsBrand
        candidate.showsLyrics = showsLyrics
        var resolved = preset.applying(to: candidate)
        resolved.reactionMode = selectedReaction
        resolved.theme = selectedTheme
        frozenRequest = resolved
        frozenTimeline = StoryRenderTimeline(
            request: resolved,
            profile: preset.exportProfile.encodingProfile(for: resolved.mode))
        elapsed = min(elapsed, frozenTimeline.lastFrameElapsed)
    }

    private func modelName(_ style: TypographyStyle) -> String {
        switch style {
        case .magazineCutout: return "Magazine Clout"
        case .vinylSticker: return "Brand Logo Clout"
        case .dymoTicket: return "Gothic & Chicano"
        case .liquidCapsule: return "Acid Zine Clout"
        default: return style.title
        }
    }

    private func chip(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text((enabled ? "✓ " : "") + title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(enabled ? selectedTheme.accent : .white)
                .padding(.horizontal, 11).frame(minHeight: 38)
                .background(enabled ? selectedTheme.accent.opacity(0.18) :
                    .white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(enabled ? selectedTheme.accent :
                    .white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(enabled ? [.isSelected] : [])
    }

    private func saveCurrentFrame() {
        guard !renderingImage else { return }
        renderingImage = true
        defer { renderingImage = false }
        do {
            let pixels = try StoryFrameRenderer.render(
                request: frozenRequest, artwork: artwork,
                frame: currentFrame, profile: encodingProfile,
                visualTimeline: visualTimeline, visualRhythm: visualRhythm)
            onSaveImage?(UIImage(cgImage: pixels))
        } catch {
            imageError = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    NightcoreBrandLockup(theme: frozenRequest.theme,
                                         iconSize: 27, titleSize: 18)
                    TrackIdentityPill(title: frozenRequest.title,
                                      artist: frozenRequest.artist,
                                      artwork: artwork, thumbnailSize: 76)
                        .accessibilityIdentifier("share.trackHeader")
                    GeometryReader { proxy in
                        let canvas = StoryExportCanvas(
                            request: frozenRequest, artwork: artwork,
                            frame: currentFrame, profile: encodingProfile,
                            visualTimeline: visualTimeline,
                            visualRhythm: visualRhythm,
                            resolvedCompositionFrame: compositionFrame)
                        let size = canvas.logicalSize
                        let scale = min(proxy.size.width / size.width,
                                        proxy.size.height / size.height)
                        canvas
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: size.width * scale,
                                   height: size.height * scale, alignment: .topLeading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .aspectRatio(CGFloat(encodingProfile.width) /
                                 CGFloat(encodingProfile.height), contentMode: .fit)
                    .frame(maxHeight: 450)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if !artworkIsLoaded {
                            ProgressView("Carregando capa").padding(12)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Fundo & Movimento").font(.headline)
                        HStack(spacing: 8) {
                            Picker("Tema visual", selection: $selectedExperienceID) {
                                ForEach(CreativePresetCatalog.all, id: \.id) { recipe in
                                    Text(recipe.preset.name).tag(recipe.id)
                                }
                                ForEach(CreativePresetCatalog.selectableExperiences) { experience in
                                    Text(experience.name).tag(experience.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("share.visualTheme")
                            Menu {
                                ForEach(AppTheme.allCases) { theme in
                                    Button(theme.displayName) { selectedTheme = theme }
                                }
                            } label: {
                                Label("⚡ Cor", systemImage: "bolt.fill")
                                    .font(.caption.bold()).padding(9)
                                    .background(.white.opacity(0.09), in: Capsule())
                            }
                            .accessibilityIdentifier("share.themeColor")
                        }
                        Text("Movimento do Fundo").font(.caption.weight(.semibold))
                        Picker("Movimento do Fundo", selection: $selectedReaction) {
                            Text("Desligado").tag(CreativePreset.AudioReaction.off)
                            Text("Fluido").tag(CreativePreset.AudioReaction.subtle)
                            Text("Reativo").tag(CreativePreset.AudioReaction.responsive)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("share.reactivityMode")
                    }
                    .padding(12)
                    .background(.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 13))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Estilo da Legenda").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TypographyStyle.storyObjectModels) { style in
                                    chip(modelName(style),
                                         enabled: showsLyrics && selectedTypography == style) {
                                        selectedTypography = style
                                        showsLyrics = true
                                    }
                                }
                                chip("Sem Legenda", enabled: !showsLyrics) {
                                    showsLyrics = false
                                }
                            }
                        }
                        .accessibilityIdentifier("share.lyricModelCycle")
                    }
                    .padding(12)
                    .background(.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 13))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Exibir no Card").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip("Capa & Música", enabled: showsTrackCard) {
                                    showsTrackCard.toggle()
                                }
                                chip("Placar Karaokê", enabled: showsScoreStamp) {
                                    showsScoreStamp.toggle()
                                }
                                .disabled(frozenRequest.scoreStamp == nil)
                                chip("Marca Nightcore Lab", enabled: showsBrand) {
                                    showsBrand.toggle()
                                }
                            }
                        }
                        .accessibilityIdentifier("share.cardToggles")
                    }
                    .padding(12)
                    .background(.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 13))

                    HStack(spacing: 10) {
                        Picker("Formato", selection: $selectedAspect) {
                            ForEach(ExportAspectRatio.allCases) { ratio in
                                Text(ratio.label).tag(ratio)
                            }
                        }.pickerStyle(.menu)
                        Picker("Qualidade", selection: $selectedQuality) {
                            ForEach(ExportQuality.allCases) { quality in
                                Text(quality.label).tag(quality)
                            }
                        }.pickerStyle(.menu)
                    }
                    Slider(value: $elapsed,
                           in: 0...max(0.05, frozenTimeline.lastFrameElapsed),
                           step: 1 / Double(encodingProfile.fps))
                        .tint(selectedTheme.accent)
                        .accessibilityLabel("Navegar pelos quadros da prévia")
                    HStack {
                        Text(String(format: "%.2f s", currentFrame.elapsed))
                        Spacer()
                        Text("\(currentFrame.index + 1) / \(frozenTimeline.frameCount) frames")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button {
                        onExport(selectedPreset, frozenRequest, artwork,
                                 visualTimeline, visualRhythm)
                    } label: {
                        Label("🎬 Exportar Vídeo (.mp4)", systemImage: "film")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(selectedTheme.accent)
                    .disabled(!artworkIsLoaded || !visualIsReady)
                    .accessibilityIdentifier("share.exportVideo")

                    Button(action: saveCurrentFrame) {
                        Label("🖼️ Salvar Imagem", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!artworkIsLoaded || renderingImage)
                    .accessibilityIdentifier("share.saveImage")

                    if !visualIsReady {
                        ProgressView("Analisando visual para exportação")
                    }
                    Text("A prévia, a imagem e o MP4 usam os mesmos quadros. O progresso do vídeo é mostrado durante a exportação.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Compartilhar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar", action: onCancel)
                }
            }
            .alert("Não foi possível salvar imagem",
                   isPresented: Binding(get: { imageError != nil },
                                        set: { if !$0 { imageError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(imageError ?? "")
            }
            .onChange(of: selectedExperienceID) { _, id in
                selectedMaterialID = CreativePresetCatalog.material(selection: id).id
                selectedTypography = CreativePresetCatalog.typographyStyle(
                    afterSelecting: id, current: selectedTypography)
            }
            .onChange(of: selectedTypography) { _, style in
                selectedTypographyPreset = CreativePresetCatalog.typographyPreset(
                    selection: selectedExperienceID, style: style,
                    font: draft.request.typographyPreset.font,
                    reacts: selectedReaction != .off)
            }
            .onChange(of: selectedPreset) { _, preset in freezeSession(preset) }
            .onChange(of: selectedTheme) { _, _ in freezeSession(selectedPreset) }
            .onChange(of: selectedReaction) { _, _ in freezeSession(selectedPreset) }
            .onChange(of: showsScoreStamp) { _, _ in freezeSession(selectedPreset) }
            .onChange(of: showsTrackCard) { _, _ in freezeSession(selectedPreset) }
            .onChange(of: showsBrand) { _, _ in freezeSession(selectedPreset) }
            .onChange(of: showsLyrics) { _, _ in freezeSession(selectedPreset) }
            .task(id: draft.id) {
                let loaded = await ShareRenderer.loadArtwork(draft.request.artworkURL)
                guard !Task.isCancelled else { return }
                artwork = loaded
                artworkIsLoaded = true
            }
            .task(id: "\(draft.id)|\(selectedReaction.rawValue)") {
                guard selectedReaction != .off,
                      let url = draft.request.reactiveSourceURL else {
                    visualTimeline = nil
                    visualRhythm = nil
                    visualIsReady = true
                    return
                }
                visualIsReady = false
                let data = try? await draft.featureEngine.analysisResult(for: url)
                guard !Task.isCancelled else { return }
                visualTimeline = data?.energyTimeline
                visualRhythm = data?.rhythmAnalysis
                visualIsReady = true
            }
        }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .preferredColorScheme(.dark)
    }
}
