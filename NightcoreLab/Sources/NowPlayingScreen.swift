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

struct NowPlayingScreen<PlayerDetails: View, Extras: View, LyricsContent: View>: View {
    let track: TrackInfo
    let clock: PlaybackClock
    let isPlaying: Bool
    let isTrackLoaded: Bool
    let canShowKaraoke: Bool
    let canSkipNext: Bool
    @Binding var appTheme: AppTheme
    @Binding var isKaraokeMode: Bool
    @Binding var lyricsCleanMode: Bool
    @Binding var backgroundStyle: BackgroundStyle
    let playerBackgroundStyle: PlayerBackgroundStyle
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    @ViewBuilder var playerDetails: () -> PlayerDetails
    @ViewBuilder var normalExtras: () -> Extras
    @ViewBuilder var karaokeContent: () -> LyricsContent

    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(PanelStore.self) private var panels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var marbleStartedAt = Date()
    @State private var isBuildingShare = false
    @State private var shareResult: ShareExportPayload?
    @State private var showShareError = false

    private var showsKaraoke: Bool { isTrackLoaded && canShowKaraoke && isKaraokeMode }
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.65, bounce: 0.15)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showsKaraoke {
                BackgroundLayer(
                    style: backgroundStyle,
                    theme: MarbleTheme(appTheme: appTheme),
                    coverURL: track.coverURL,
                    marbleStartedAt: marbleStartedAt
                )
                .transition(.opacity)
            } else {
                // Keep the Liquid Marble visible when panels are collapsed.
                // One full-screen shader is enough; it pauses with Reduce Motion
                // and when the app moves out of the foreground.
                TurbulentMarbleView(
                    theme: MarbleTheme(appTheme: appTheme),
                    speed: 0.6,
                    maxFPS: 30,
                    startedAt: marbleStartedAt
                )
                .overlay(Color.black.opacity(0.4))
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                if isTrackLoaded {
                    unifiedPlayerCard
                        .padding(.horizontal, 20)
                        // Keep the overlay controls in their own row.
                        .padding(.top, 74)
                        .hideablePanel(.player, edge: .top)
                }

                if showsKaraoke {
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
                // Keep SearchView and its engine/cache alive while temporarily covered.
                normalExtras()
                    .padding(.top, isTrackLoaded && panels.isVisible(.player) ? 0 : 74)
                    .frame(height: showsKaraoke || panels.isZen ? 0 : nil)
                    .opacity(showsKaraoke || panels.isZen ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!showsKaraoke && !panels.isZen)
                    .accessibilityHidden(showsKaraoke || panels.isZen)
            }
        }
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
        .overlay(alignment: .topLeading) {
            EnvironmentBar(theme: $appTheme,
                           panels: showsKaraoke ? PanelID.karaokePanels : PanelID.mainPanels)
                .padding(.top, 16)
                .padding(.leading, 16)
        }
        .overlay(alignment: .topTrailing) {
            if isTrackLoaded {
                HStack(spacing: 8) {
                    ShareButton(isWorking: isBuildingShare, action: shareCurrentTrack)
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
        .alert("Não foi possível criar o cartão", isPresented: $showShareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Tente compartilhar novamente. A reprodução continua normalmente.")
        }
        .environment(\.colorScheme, .dark)
        .onAppear { lyricsStore.attach(clock: clock) }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isKaraokeMode)
    }

    /// A antiga janela Reprodução agora é a metade inferior deste cartão.
    /// O mesmo card recebe a capa, transporte, scrubber e metal líquido.
    private var unifiedPlayerCard: some View {
        VStack(spacing: showsKaraoke ? 0 : 10) {
            PlayerHeader(
                track: track,
                isPlaying: isPlaying,
                compact: showsKaraoke,
                canSkipNext: canSkipNext,
                onPlayPause: onPlayPause,
                onPrevious: onPrevious,
                onNext: onNext
            )
            if !showsKaraoke {
                playerDetails()
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, showsKaraoke ? 12 : 14)
        .padding(.vertical, showsKaraoke ? 10 : 14)
        .background {
            if !showsKaraoke {
                PlayerBackgroundView(style: playerBackgroundStyle,
                                     imageURL: track.coverURL,
                                     theme: appTheme)
                    .id(track.coverURL)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous),
                      theme: appTheme, isActive: isPlaying, pulses: false, depth: 0.7)
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
        isBuildingShare = true
        Task { @MainActor in
            defer { isBuildingShare = false }
            do {
                let image = try await ShareRenderer.render(snapshot)
                try Task.checkCancellation()
                shareResult = ShareExportPayload(image: image)
            } catch {
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
    let canSkipNext: Bool
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        // Vertical (player aberto) <-> horizontal (mini-player no topo).
        let layout = compact ? AnyLayout(HStackLayout(spacing: 12))
                             : AnyLayout(VStackLayout(spacing: 11))
        layout {
            CoverArt(url: track.coverURL)
                .frame(width: compact ? 52 : 192, height: compact ? 52 : 192)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 28, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: compact ? 6 : 30, y: compact ? 2 : 14)

            VStack(alignment: compact ? .leading : .center, spacing: 2) {
                Text(track.title).font(.title3.weight(.bold)).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)

            Transport(isPlaying: isPlaying, compact: compact, canSkipNext: canSkipNext,
                      onPlayPause: onPlayPause, onPrevious: onPrevious, onNext: onNext)
        }
    }
}

private struct Transport: View {
    let isPlaying: Bool
    let compact: Bool
    let canSkipNext: Bool
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            skip("backward.fill", label: "Reiniciar faixa", enabled: true, action: onPrevious)

            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.black)
                    .frame(width: compact ? 44 : 64, height: compact ? 44 : 64)
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

    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        ZStack {
            switch style {
            case .marble:
                TurbulentMarbleView(theme: theme, speed: 0.8,
                                    maxFPS: lowPower ? 30 : 60,
                                    startedAt: marbleStartedAt)
                    .transition(.opacity)
            case .cover:
                BlurredCover(url: coverURL)
                    .transition(.opacity)
            }
            Color.black.opacity(0.35)               // scrim: contraste do preenchimento das letras
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: style)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
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