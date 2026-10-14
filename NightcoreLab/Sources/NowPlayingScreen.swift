import SwiftUI

// =============================================================================
// Depende de: LyricsStore (environment), KaraokeLyricsView, PlaybackClock,
//             KaraokeTheme, TurbulentMarbleView, MarbleTheme  (arquivos anteriores)
// =============================================================================

// MARK: - Preferências persistidas

enum BackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case marble     // shader Metal
    case cover      // capa com blur forte

    var id: String { rawValue }
    var toggled: BackgroundStyle { self == .marble ? .cover : .marble }
    /// Ícone = DESTINO do toque (o que você vai ver ao tocar).
    var icon: String { self == .marble ? "photo.fill" : "sparkles" }
    var accessibilityName: String { self == .marble ? "Mármore líquido" : "Capa desfocada" }
}

enum KaraokePrefs {
    static let background = "karaoke.backgroundStyle"
}

extension MarbleTheme {
    var title: String { rawValue.capitalized }
    /// Mesmo tema pinta o fundo (marble) e o preenchimento das letras.
    var karaoke: KaraokeTheme {
        switch self {
        case .acid:    return .acid
        case .cyber:   return .cyber
        case .crimson: return .crimson
        case .ultraviolet: return .ultraviolet
        case .solar: return .solar
        case .orchid: return .orchid
        case .sapphire: return .sapphire
        case .atomic: return .atomic
        case .lagoon: return .lagoon
        case .volt: return .volt
        case .prism: return .prism
        case .magma: return .magma
        case .noir: return .noir
        case .ultrapink:   return .ultrapink
        case .ultraorange: return .ultraorange
        case .purewhite:   return .purewhite
        case .ultrablack:  return .ultrablack
        }
    }
}

/// Adaptador do Track real: title e thumbnailURL, sem artist estruturado.
struct TrackInfo: Equatable {
    let id: String
    let title: String
    let artist: String
    let coverURL: URL?

    init(track: Track?, fileName: String?, coverURL: URL?) {
        id = track?.id ?? (fileName.map { "local:\($0)" } ?? "idle")
        title = track?.cleanTitle ?? track?.title ?? fileName ?? "Nenhuma música"
        artist = track?.cleanArtist
            ?? track.flatMap { LyricsMatcher.identity(from: $0.title)?.artist }
            ?? (track == nil ? "Arquivo local" : "YouTube")
        self.coverURL = coverURL ?? track?.thumbnailURL
    }
}

// MARK: - Tela

struct NowPlayingScreen<Header: View, PlayerDetails: View, Extras: View, LyricsContent: View>: View {
    let track: TrackInfo
    let clock: PlaybackClock
    let audio: AudioEngineManager
    let isScrollDisabled: Bool
    let isPlaying: Bool
    let isTrackLoaded: Bool
    let canShowKaraoke: Bool
    let hasPreviousTrack: Bool
    let canSkipNext: Bool
    @Binding var appTheme: AppTheme
    @Binding var isKaraokeMode: Bool
    @Binding var lyricsCleanMode: Bool
    @Binding var backgroundStyle: BackgroundStyle
    let playerBackgroundStyle: PlayerBackgroundStyle
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    @ViewBuilder var header: () -> Header
    @ViewBuilder var playerDetails: () -> PlayerDetails
    @ViewBuilder var normalExtras: () -> Extras
    @ViewBuilder var karaokeContent: () -> LyricsContent

    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(PanelStore.self) private var panels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var marbleStartedAt = Date()
    @State private var visualEngine = AudioFeatureEngine()
    /// Observed only by LiveMarbleDistortion leaves (Stage 10C): reactive
    /// updates no longer re-evaluate this whole screen at 12 Hz.
    @State private var liveUniforms = CreativeLiveUniforms()
    @State private var suggestedSongProfile: SongCreativeProfile?
    @State private var activeSongProfile: SongCreativeProfile?
    @State private var songProfileStore = CreativePresetPackageStore()
    @AppStorage("creativeReactionMode")
    private var reactionMode: CreativePreset.AudioReaction = .off
    @AppStorage(CreativePresetCatalog.storageKey)
    private var creativePresetID = CreativePresetCatalog.defaultID
    @AppStorage("karaokeTypography")
    private var karaokeTypography: TypographyStyle = .neon

    @State private var isBuildingShare = false
    @State private var frozenShareMarblePhase: Float?
    @State private var shareResult: ShareExportPayload?
    @State private var showShareError = false
    @State private var shareErrorDetails: String?
    @State private var storyProgress = 0.0
    @State private var storyPreview: StoryVideoPayload?
    @State private var storyDraft: StoryVideoDraft?
    @State private var storyTask: Task<Void, Never>?
    @AppStorage("story.lyricTypography") private var storyTypography: TypographyFont = .classic

    private var showsKaraoke: Bool { isTrackLoaded && canShowKaraoke && isKaraokeMode }
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.65, bounce: 0.15)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showsKaraoke {
                LiveMarbleDistortion(uniforms: liveUniforms) { distortion, pulse in
                    BackgroundLayer(
                        style: backgroundStyle,
                        theme: MarbleTheme(appTheme: appTheme),
                        coverURL: track.coverURL,
                        marbleStartedAt: marbleStartedAt,
                        frozenTime: frozenShareMarblePhase,
                        reactiveDistortion: distortion,
                        pulseDriver: pulse,
                        material: CreativePresetCatalog.material(selection: creativePresetID)
                    )
                }
                .transition(.opacity)
            } else {
                // Keep the Liquid Marble visible when panels are collapsed.
                // One full-screen shader is enough; it pauses with Reduce Motion
                // and when the app moves out of the foreground.
                LiveMarbleDistortion(uniforms: liveUniforms) { distortion, pulse in
                    TurbulentMarbleView(
                        theme: MarbleTheme(appTheme: appTheme),
                        speed: 0.6,
                        maxFPS: 30,
                        frozenTime: frozenShareMarblePhase,
                        startedAt: marbleStartedAt,
                        reactiveDistortion: distortion,
                        material: CreativePresetCatalog.material(selection: creativePresetID),

                        pulseDriver: pulse
                    )
                }
                .overlay(Color.black.opacity(0.4))
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                if showsKaraoke {
                    if isTrackLoaded {
                        unifiedPlayerCard
                            .padding(.horizontal, 20)
                            .padding(.top, 74)
                            .hideablePanel(.player, edge: .top)
                    }
                    karaokeContent()
                        .padding(.top, 8)
                        .hideablePanel(.lyrics, edge: .bottom, keepsSpace: true)
                        .transition(.lyricsReveal)
                    if KaraokeCleanLayout.showsQuickThemeBar(cleanMode: lyricsCleanMode) {
                        KaraokeBottomBar(theme: $appTheme, background: $backgroundStyle)
                            .padding(.bottom, 12)
                            .hideablePanel(.themes, edge: .bottom)
                            .transition(.barRise)
                    }
                }

                // Header always precedes the centered player. The Music, Audio
                // and Export sections remain below the first viewport in order.
                // Both header and player still obey the eye visibility controls.
                GeometryReader { viewport in
                    ScrollView {
                        VStack(spacing: 0) {
                            if isTrackLoaded {
                                VStack(spacing: 0) {
                                    header()
                                        .padding(.horizontal, 20)
                                        .padding(.top, 74)
                                        .hideablePanel(.header, edge: .top)
                                    Spacer(minLength: 12)
                                    unifiedPlayerCard
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.horizontal, 20)
                                        .hideablePanel(.player, edge: .top)
                                    Spacer(minLength: 12)
                                }
                                .frame(minHeight: viewport.size.height)
                            } else {
                                // Keep the import shortcut close to discovery
                                // when no track is loaded, without a blank hero.
                                header()
                                    .padding(.horizontal, 20)
                                    .padding(.top, 74)
                                    .padding(.bottom, 12)
                                    .hideablePanel(.header, edge: .top)
                            }
                            normalExtras()
                                .padding(.top, isTrackLoaded ? 0 : 8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollDisabled(isScrollDisabled || showsKaraoke || panels.isZen)
                }
                .frame(height: showsKaraoke || panels.isZen ? 0 : nil)
                .opacity(showsKaraoke || panels.isZen ? 0 : 1)
                .clipped()
                .allowsHitTesting(!showsKaraoke && !panels.isZen)
                .accessibilityHidden(showsKaraoke || panels.isZen)
            }
        }
        // Stage 12.5: the karaoke reads the live feature envelope from here
        // (optional environment: other hosts simply get no features).
        .environment(liveUniforms)
        .overlay {
            if panels.isZen {
                // Toque em qualquer área livre revela o layout; estados individuais
                // de cada painel não mudam quando alternamos Zen.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { panels.setZen(false) }
            }
        }
        .overlay(alignment: .top) {
            if isTrackLoaded {
                Button {
                    applySuggestedSongProfile()
                } label: {
                    Label("Criar", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 36)
                        .foregroundStyle(.white)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("songCreativeProfile.apply")
                .contextMenu {
                    ForEach(CreativePresetCatalog.selectableExperiences) { experience in
                        Button(experience.name) {
                            applySuggestedSongProfile(experienceID: experience.id)
                        }
                    }
                }
                .padding(.top, 18)
            }
        }
        .overlay(alignment: .topLeading) {
            EnvironmentBar(theme: $appTheme,
                           panels: showsKaraoke ? PanelID.karaokePanels : PanelID.mainPanels)
                .padding(.top, 16)
                .padding(.leading, 16)
        }
        .overlay(alignment: .topTrailing) {
            if isTrackLoaded {
                HStack(spacing: 8) {
                    ShareButton(
                        isWorking: isBuildingShare,
                        canExportLyrics: lyricsStore.trackID == track.id &&
                            lyricsStore.status == .ready && !lyricsStore.lines.isEmpty,
                        typography: $storyTypography,
                        onImage: shareCurrentTrack,
                        onVideo: { mode, includeAudio in
                            shareVideo(mode: mode, includeAudio: includeAudio)
                        }
                    )
                    if canShowKaraoke {
                        micButton
                    }
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
            }
        }
        .sheet(item: $shareResult) { payload in
            ShareExportService(image: payload.image)
        }
        .sheet(item: $storyDraft) { draft in
            StoryDraftPreview(
                draft: draft,
                onExport: { preset, frozenRequest, artwork, visualTimeline, visualRhythm in
                    storyDraft = nil
                    exportApprovedDraft(draft, request: frozenRequest,
                                        selectedProfile: preset.exportProfile,
                                        artwork: artwork,
                                        visualTimeline: visualTimeline,
                                        visualRhythm: visualRhythm)
                },
                onCancel: { storyDraft = nil }
            )
        }
        .sheet(item: $storyPreview) { payload in
            StoryVideoPreview(url: payload.url, package: payload.package)
        }
        .overlay(alignment: .bottom) {
            if isBuildingShare && storyTask != nil {
                VStack(spacing: 10) {
                    ProgressView(value: storyProgress)
                        .tint(appTheme.accent)
                    HStack {
                        Text("Gerando Story · \(Int(storyProgress * 100))%")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Cancelar") { storyTask?.cancel() }
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(16)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
        .alert("Não foi possível criar o cartão", isPresented: $showShareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareErrorDetails ??
                 "Tente compartilhar novamente. A reprodução continua normalmente.")
        }
        .environment(\.colorScheme, .dark)
        .onAppear { lyricsStore.attach(clock: clock) }

        .task(id: track.id) {
            // Cache-only handoff, off the touch/audio thread. No FFT is run
            // just to open Player; rejected/missing evidence uses Original.
            let expectedTrack = track.id
            activeSongProfile = nil
            suggestedSongProfile = nil
            guard let url = audio.visualAnalysisURL, url.isFileURL else {
                suggestedSongProfile = SongCreativeProfileResolver.suggest(
                    assetID: expectedTrack, sourceRevision: "not-analyzed",
                    analysis: nil, expression: nil)
                return
            }
            let descriptor = await Task.detached(priority: .utility) {
                try? AudioAssetDescriptor.read(at: url)
            }.value
            guard !Task.isCancelled, track.id == expectedTrack else { return }
            guard let descriptor else {
                suggestedSongProfile = SongCreativeProfileResolver.suggest(
                    assetID: expectedTrack, sourceRevision: "not-analyzed",
                    analysis: nil, expression: nil)
                return
            }
            let analysis = await MusicAnalysisCache().load(for: descriptor)
            // Exact audited v1 fingerprints prevent unknown/stale expression
            // algorithms from silently affecting the creative scene.
            let expression = await ExpressionCache().load(
                for: descriptor,
                requiring: SongCreativeProfileResolver.acceptedExpressionFingerprints)
            let saved = await songProfileStore.loadSongProfile(
                assetID: descriptor.assetID,
                sourceRevision: descriptor.sourceRevision)
            guard !Task.isCancelled, track.id == expectedTrack else { return }
            suggestedSongProfile = saved ?? SongCreativeProfileResolver.suggest(
                assetID: descriptor.assetID,
                sourceRevision: descriptor.sourceRevision,
                analysis: analysis, expression: expression)
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isKaraokeMode)
    }

    /// A single user action swaps existing observable visual/pad metadata
    /// and one live reverb parameter. No AVAudioEngine rebuild, seek or clock
    /// reset; the prepared Performance PadKit remains the original kit.
    private func applySuggestedSongProfile(experienceID: String? = nil) {
        let base = suggestedSongProfile ??
            SongCreativeProfileResolver.suggest(
                assetID: track.id, sourceRevision: "not-analyzed",
                analysis: nil, expression: nil)
        let profile: SongCreativeProfile
        if let experienceID,
           let selected = CreativePresetCatalog.selectedExperience(id: experienceID) {
            profile = SongCreativeProfile(
                assetID: base.assetID, sourceRevision: base.sourceRevision,
                visualPresetID: selected.id, materialID: selected.visualMaterial.id,
                typographyPreset: selected.typographyPreset,
                padMapping: base.padMapping,
                vocalAndAudioFXMacro: base.vocalAndAudioFXMacro,
                reactionProfile: base.reactionProfile)
        } else {
            profile = base
        }
        guard profile.isValid else { return }
        // Existing AppStorage keys are the source of truth for visual and
        // typography consumers, including frozen Story requests.
        creativePresetID = profile.visualPresetID
        karaokeTypography = profile.typographyPreset.style
        reactionMode = profile.reactionProfile
        audio.setReverb(Float(profile.vocalAndAudioFXMacro * 35))
        activeSongProfile = profile
        try? CreatorPresetStore.save(
            SongCreativeProfileResolver.creatorPreset(for: profile))
        Task { try? await songProfileStore.saveSongProfile(profile) }
    }

    /// A antiga janela Reprodução agora é a metade inferior deste cartão.
    /// O mesmo card recebe a capa, transporte, scrubber e metal líquido.
    private var unifiedPlayerCard: some View {
        VStack(spacing: showsKaraoke ? 0 : 8) {
            PlayerHeader(
                track: track,
                isPlaying: isPlaying,
                compact: showsKaraoke,
                hasPreviousTrack: hasPreviousTrack,
                canSkipNext: canSkipNext,
                onPlayPause: onPlayPause,
                onPrevious: onPrevious,
                onNext: onNext
            )
            if !showsKaraoke {
                playerDetails()
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, showsKaraoke ? 12 : 12)
        .padding(.vertical, showsKaraoke ? 10 : 11)
        .background {
            if !showsKaraoke {
                LiveMarbleDistortion(uniforms: liveUniforms) { distortion, pulse in
                    PlayerBackgroundView(style: playerBackgroundStyle,
                                         imageURL: track.coverURL,
                                         theme: appTheme,
                                         frozenTime: frozenShareMarblePhase,
                                         reactiveDistortion: distortion,
                                         pulseDriver: pulse, material: CreativePresetCatalog.material(selection: creativePresetID))
                }
                .id(track.coverURL)
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous),
                      theme: appTheme, isActive: isPlaying, pulses: false, depth: 0.7)
        .overlay {
            CreativeReactiveAccent(
                sourceURL: audio.visualAnalysisURL,
                clock: clock,
                theme: appTheme,
                backgroundStyle: playerBackgroundStyle,
                featureEngine: visualEngine,
                onParameters: { next in liveUniforms.update(next) },
                onPulseDriver: { driver in liveUniforms.setPulseDriver(driver) },
                onFeatureTimeline: { timeline in liveUniforms.setFeatureTimeline(timeline) }
            )
        }
    }

    /// Freeze only the live visuals while exporting. The audio keeps playing.
    private func beginShare(at instant: Date) {
        liveUniforms.freeze()
        frozenShareMarblePhase = Float(max(0, instant.timeIntervalSince(marbleStartedAt)) *
                                       (showsKaraoke ? 0.8 : 0.6))
        isBuildingShare = true
    }

    private func finishShare() {
        isBuildingShare = false
        frozenShareMarblePhase = nil
        liveUniforms.unfreeze()
    }

    /// Congela a fase exibida agora; nunca reinicia o áudio nem cria outro shader animado.
    private func shareCurrentTrack() {
        guard isTrackLoaded, !isBuildingShare else { return }
        let capturedAt = Date()
        let style: ShareSnapshot.VisualStyle = showsKaraoke && backgroundStyle == .cover
            ? .blurredArtwork : .marble
        let snapshot = ShareSnapshotBuilder.make(
            track: track,
            theme: appTheme,
            visualStyle: style,
            marbleStartedAt: marbleStartedAt,
            speed: showsKaraoke ? 0.8 : 0.6,
            capturedAt: capturedAt
        )
        beginShare(at: capturedAt)
        Task { @MainActor in
            defer { finishShare() }
            do {
                let image = try await ShareRenderer.render(snapshot)
                try Task.checkCancellation()
                shareResult = ShareExportPayload(image: image)
            } catch {
                shareErrorDetails = error.localizedDescription
                showShareError = true
            }
        }
    }

    /// Capture timing, DSP and lyrics before the first suspension point.
    private func shareVideo(mode: StoryMode, includeAudio: Bool) {
        guard isTrackLoaded, !isBuildingShare else { return }
        let matchedLyrics = lyricsStore.trackID == track.id &&
            lyricsStore.status == .ready ? lyricsStore.lines : []
        do {
            let capturedAt = Date()
            let frame = try StoryRequestBuilder.make(
                mode: mode, track: track, theme: appTheme,
                playerStyle: playerBackgroundStyle, karaokeBackground: backgroundStyle,
                marblePhase: Float(max(0, capturedAt.timeIntervalSince(marbleStartedAt)) *
                                   (showsKaraoke ? 0.8 : 0.6)),
                playbackTime: audio.playbackTime, sourceDuration: audio.duration,
                speed: audio.speed, lines: matchedLyrics,
                lyricOffset: lyricsStore.userOffset, typography: storyTypography,
                typographyStyle: karaokeTypography,
                includeAudio: includeAudio,
                reactiveProgram: (reactionMode == .off ||
                                  reduceMotion ||
                                  ProcessInfo.processInfo.isLowPowerModeEnabled)
                    ? nil : CreativePresetCatalog.effectiveProgram(
                        id: creativePresetID, theme: appTheme,
                        typography: karaokeTypography,
                        background: playerBackgroundStyle, reaction: reactionMode),
                reactiveSourceURL: audio.visualAnalysisURL,
                creativePresetID: creativePresetID
            )
            let frozenAudio = try includeAudio ? audio.storyAudioSource() : nil
            // Preview and export share the exact same immutable snapshot,
            // artwork and frame-rate profile. No video work starts until
            // the user approves the visual preview.
            storyDraft = StoryVideoDraft(
                request: frame,
                audioSource: frozenAudio,
                profile: StoryEncodingProfile.recommended(),
                featureEngine: visualEngine
            )
        } catch {
            shareErrorDetails = error.localizedDescription
            showShareError = true
        }
    }

    private func exportApprovedDraft(_ draft: StoryVideoDraft,
                                     request: StoryVideoRequest,
                                     selectedProfile: ExportProfile,
                                     artwork: UIImage?,
                                     visualTimeline: AudioFeatureTimeline?,
                                     visualRhythm: RhythmAnalysisResult?) {
        guard !isBuildingShare else { return }
        storyProgress = 0
        beginShare(at: Date())
        storyTask = Task { @MainActor in
            defer {
                finishShare()
                storyTask = nil
            }
            do {
                let package = try await SharePackageBuilder.build(
                    request: request, audioSource: draft.audioSource,
                    artwork: artwork, selectedProfile: selectedProfile,
                    visualTimeline: visualTimeline, visualRhythm: visualRhythm,
                    progress: { storyProgress = $0 }
                )
                try Task.checkCancellation()
                storyPreview = StoryVideoPayload(package: package)
            } catch is CancellationError {
                // User cancellation does not interrupt normal playback.
            } catch {
                shareErrorDetails = error.localizedDescription
                showShareError = true
            }
        }
    }

    private var micButton: some View {
        Button {
            withAnimation(motion) { isKaraokeMode.toggle() }
        } label: {
            Image(systemName: showsKaraoke ? "mic.fill" : "mic")
                .font(.system(size: 18, weight: .semibold))
                .symbolEffect(.bounce, value: showsKaraoke)
                .frame(width: 44, height: 44)
                .background(showsKaraoke
                            ? MarbleTheme(appTheme: appTheme).palette.body.opacity(0.28)
                            : Color.white.opacity(0.10), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsKaraoke ? "Sair do modo karaokê" : "Entrar no modo karaokê")
    }
}

// MARK: - Coreografia (entrada escalonada, saída rápida)

private extension AnyTransition {
    /// Letras: esperam o header chegar ao topo, depois aparecem.
    static var lyricsReveal: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.40).delay(0.25)),
            removal:   .opacity.animation(.easeIn(duration: 0.15))
        )
    }
    /// Barra inferior: sobe com mola logo depois das letras começarem.
    static var barRise: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity)
                .animation(.spring(duration: 0.6, bounce: 0.2).delay(0.12)),
            removal: .move(edge: .bottom).combined(with: .opacity)
                .animation(.easeIn(duration: 0.2))
        )
    }
}

struct LyricsFadeMask: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.00),
            .init(color: .black, location: 0.10),
            .init(color: .black, location: 0.88),
            .init(color: .clear, location: 1.00),
        ], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Header: mesma view, dois layouts (AnyLayout preserva identidade)

private struct PlayerHeader: View {
    let track: TrackInfo
    let isPlaying: Bool
    let compact: Bool
    let hasPreviousTrack: Bool
    let canSkipNext: Bool
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        // Vertical (player aberto) <-> horizontal (mini-player no topo).
        let layout = compact ? AnyLayout(HStackLayout(spacing: 12))
                             : AnyLayout(VStackLayout(spacing: 9))
        layout {
            CoverArt(url: track.coverURL)
                .frame(width: compact ? 52 : 164, height: compact ? 52 : 164)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 28, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: compact ? 6 : 30, y: compact ? 2 : 14)

            VStack(alignment: compact ? .leading : .center, spacing: 2) {
                Text(track.title).font(.title3.weight(.bold)).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)

            Transport(isPlaying: isPlaying, compact: compact,
                      hasPreviousTrack: hasPreviousTrack, canSkipNext: canSkipNext,
                      onPlayPause: onPlayPause, onPrevious: onPrevious, onNext: onNext)
        }
    }
}

private struct Transport: View {
    let isPlaying: Bool
    let compact: Bool
    let hasPreviousTrack: Bool
    let canSkipNext: Bool
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            skip("backward.fill",
                 label: hasPreviousTrack ? "Faixa anterior" : "Reiniciar faixa",
                 enabled: true, action: onPrevious)

            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.black)
                    .frame(width: compact ? 44 : 60, height: compact ? 44 : 60)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pausar" : "Tocar")

            skip("forward.fill", label: "Próxima faixa", enabled: canSkipNext, action: onNext)
        }
    }

    /// Anterior/próxima encolhem para largura 0 no modo compacto (valores numéricos = animáveis).
    private func skip(_ name: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || compact)
        .frame(width: compact ? 0 : 56, height: 44)
        .opacity(compact ? 0 : (enabled ? 1 : 0.35))
        .clipped()
        .accessibilityHidden(compact)
        .accessibilityLabel(label)
    }
}

private struct CoverArt: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.3))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle().fill(.white.opacity(0.08))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.4)))
            }
        }
    }
}

// MARK: - Fundo (alternável)

private struct BackgroundLayer: View {
    let style: BackgroundStyle
    let theme: MarbleTheme
    let coverURL: URL?
    let marbleStartedAt: Date
    var frozenTime: Float? = nil
    var reactiveDistortion: Double = 0
    var pulseDriver: MarblePulseDriver? = nil
    var material: VisualMaterial = .legacyMarble

    @Environment(\.energyBudget) private var energyBudget

    var body: some View {
        ZStack {
            switch style {
            case .marble:
                TurbulentMarbleView(theme: theme, speed: 0.8,
                                    maxFPS: energyBudget.maxVisualFPS,
                                    frozenTime: frozenTime,
                                    startedAt: marbleStartedAt,
                                    reactiveDistortion: reactiveDistortion,
                                    material: material,

                                    pulseDriver: pulseDriver)
                    .transition(.opacity)
            case .cover:
                BlurredCover(url: coverURL)
                    .transition(.opacity)
            }
            Color.black.opacity(0.35)               // scrim: contraste do preenchimento das letras
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: style)

    }
}

private struct BlurredCover: View {
    let url: URL?

    var body: some View {
        GeometryReader { viewport in
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.45))) { phase in
                ZStack {
                    Color.black

                    if case .success(let image) = phase {
                        // Ambient fill can crop, since it is intentionally blurred.
                        // Bound it to the viewport BEFORE the blur; never zoom the whole image.
                        image.resizable()
                            .scaledToFill()
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .clipped()
                            .blur(radius: 32)
                            .overlay(Color.black.opacity(0.30))

                        // Main artwork stays entirely visible, even for 16:9 videos.
                        // Lyrics remain legible because the card is softly subdued.
                        image.resizable()
                            .scaledToFit()
                            .frame(width: KaraokeLayoutMetrics.coverEdge(for: viewport.size),
                                   height: KaraokeLayoutMetrics.coverEdge(for: viewport.size))
                            .opacity(0.66)
                            .blur(radius: 2)
                            .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
            }
            .id(url) // A change of track replaces both images together.
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Barra inferior: temas + toggle de fundo

private struct KaraokeBottomBar: View {
    @Binding var theme: AppTheme
    @Binding var background: BackgroundStyle
    @AppStorage("karaokeTypography") private var typography: TypographyStyle = .neon
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 16) {
            // Todos os temas usam rolagem e centralização da seleção.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AppTheme.allCases) { t in
                            Button {
                                withAnimation(.snappy(duration: 0.35)) { theme = t }
                            } label: { swatch(t) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(t.displayName)
                            .accessibilityValue(t.dominantColorName)
                            .accessibilityAddTraits(theme == t ? .isSelected : [])
                            .id(t.id)  // necessário para scrollTo centralizar este botão
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: 232)
                .onAppear { proxy.scrollTo(theme.id, anchor: .center) }
                .onChange(of: theme) { _, newTheme in
                    withAnimation(.snappy(duration: 0.35)) {
                        proxy.scrollTo(newTheme.id, anchor: .center)
                    }
                }
            }

            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 26)

            Menu {
                Picker("Tipografia", selection: $typography) {
                    ForEach(TypographyStyle.allCases) { template in
                        Text(template.title).tag(template)
                    }
                }
            } label: {
                Image(systemName: "textformat.alt")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Template das letras")
            .accessibilityValue(typography.title)

            Button {
                withAnimation(.smooth(duration: 0.6)) { background = background.toggled }
            } label: {
                Image(systemName: background.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Alternar fundo")
            .accessibilityValue(background.accessibilityName)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    private func swatch(_ t: AppTheme) -> some View {
        let p = MarbleTheme(appTheme: t).palette
        return ZStack {
            if theme == t {
                Circle().strokeBorder(.white, lineWidth: 2)
                    .frame(width: 40, height: 40)
                    .matchedGeometryEffect(id: "selection-ring", in: ns)   // o anel desliza entre temas
            }
            Circle()
                .fill(LinearGradient(colors: [p.body, p.glow], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
        }
        .frame(width: 40, height: 40)
    }
}