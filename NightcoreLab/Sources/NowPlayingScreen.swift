import SwiftUI

// =============================================================================
// Depende de: LyricsStore (environment), KaraokeLyricsView, PlaybackClock,
//             KaraokeTheme, TurbulentMarbleView, MarbleTheme  (arquivos anteriores)
// =============================================================================

// MARK: - Preferências persistidas

enum BackgroundStyle: String, CaseIterable, Identifiable {
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
        title = track?.title ?? fileName ?? "Nenhuma música"
        artist = track.flatMap { LyricsMatcher.identity(from: $0.title)?.artist }
            ?? (track == nil ? "Arquivo local" : "YouTube")
        self.coverURL = coverURL ?? track?.thumbnailURL
    }
}

// MARK: - Tela

struct NowPlayingScreen<Extras: View, LyricsContent: View>: View {
    let track: TrackInfo
    let clock: PlaybackClock
    let isPlaying: Bool
    let isTrackLoaded: Bool
    let canShowKaraoke: Bool
    let canSkipNext: Bool
    @Binding var appTheme: AppTheme
    @Binding var isKaraokeMode: Bool
    @Binding var visibleDiscover: Bool
    @Binding var visibleQueue: Bool
    @Binding var visiblePlayback: Bool
    @Binding var visiblePresets: Bool
    @Binding var visibleControls: Bool
    @Binding var visibleExport: Bool
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    @ViewBuilder var normalExtras: () -> Extras
    @ViewBuilder var karaokeContent: () -> LyricsContent

    @AppStorage(KaraokePrefs.background) private var backgroundStyle: BackgroundStyle = .marble
    @AppStorage("isZenMode") private var isZenMode = false
    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    coverURL: track.coverURL
                )
                .transition(.opacity)
            } else {
                // Keep the Liquid Marble visible when panels are collapsed.
                // One full-screen shader is enough; it pauses with Reduce Motion
                // and when the app moves out of the foreground.
                TurbulentMarbleView(
                    theme: MarbleTheme(appTheme: appTheme),
                    speed: 0.6,
                    maxFPS: 30
                )
                .overlay(Color.black.opacity(0.4))
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                if isTrackLoaded {
                    PlayerHeader(
                        track: track,
                        isPlaying: isPlaying,
                        compact: showsKaraoke,
                        canSkipNext: canSkipNext,
                        onPlayPause: onPlayPause,
                        onPrevious: onPrevious,
                        onNext: onNext
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, showsKaraoke ? 12 : 22)
                    .padding(.trailing, showsKaraoke ? 48 : 0)
                }

                if showsKaraoke {
                    karaokeContent()
                        .padding(.top, 8)
                        .transition(.lyricsReveal)
                    KaraokeBottomBar(theme: $appTheme, background: $backgroundStyle)
                        .padding(.bottom, 12)
                        .transition(.barRise)
                } else if !isZenMode {
                    // Somente o conteúdo inferior sai da hierarquia; artwork,
                    // transporte e fundo Metal permanecem intactos.
                    normalExtras()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if !isKaraokeMode {
                HStack(spacing: 8) {
                    zenButton
                    layoutMenu
                }
                .padding(.top, 16)
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isTrackLoaded && canShowKaraoke { micButton }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { lyricsStore.attach(clock: clock) }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isKaraokeMode)
    }

    /// Menu disponível mesmo em Zen Mode; não altera as preferências de expansão.
    private var layoutMenu: some View {
        Menu {
            Section("Música e sugestões") {
                Toggle("Descobrir", isOn: $visibleDiscover)
                Toggle("A Seguir", isOn: $visibleQueue)
                Toggle("Reprodução", isOn: $visiblePlayback)
            }
            Section("Ferramentas") {
                Toggle("Presets", isOn: $visiblePresets)
                Toggle("Controles", isOn: $visibleControls)
                Toggle("Exportar", isOn: $visibleExport)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.10), in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Personalizar seções visíveis")
        .accessibilityHint("Mostrar ou ocultar Descobrir, A Seguir e demais painéis")
    }

    /// Contraponto do botão do karaokê: mantém-se acessível mesmo sem faixa.
    private var zenButton: some View {
        Button {
            withAnimation(motion) { isZenMode.toggle() }
        } label: {
            Image(systemName: isZenMode ? "moon.stars.fill" : "moon.zzz")
                .font(.system(size: 18, weight: .semibold))
                .symbolEffect(.bounce, value: isZenMode)
                .frame(width: 44, height: 44)
                .background(isZenMode
                            ? MarbleTheme(appTheme: appTheme).palette.body.opacity(0.28)
                            : Color.white.opacity(0.10), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isZenMode ? "Desativar modo Zen" : "Ativar modo Zen")
        .accessibilityValue(isZenMode ? "Ativado" : "Desativado")
        .accessibilityHint("Oculta ou mostra os painéis abaixo do player")
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
        .padding(.top, 16)
        .padding(.trailing, 16)
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
                             : AnyLayout(VStackLayout(spacing: 16))
        layout {
            CoverArt(url: track.coverURL)
                .frame(width: compact ? 52 : 224, height: compact ? 52 : 224)
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
                    .frame(width: compact ? 44 : 72, height: compact ? 44 : 72)
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

    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        ZStack {
            switch style {
            case .marble:
                TurbulentMarbleView(theme: theme, speed: 0.8, maxFPS: lowPower ? 30 : 60)
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
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.5))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
                    .saturation(1.35)
            default:
                Color.black
            }
        }
        .blur(radius: 50)
        .scaleEffect(1.3)           // esconde a borda transparente que o blur cria
        .clipped()
        .id(url)                    // troca de faixa = crossfade
    }
}

// MARK: - Barra inferior: temas + toggle de fundo

private struct KaraokeBottomBar: View {
    @Binding var theme: AppTheme
    @Binding var background: BackgroundStyle
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(AppTheme.allCases) { t in
                    Button {
                        withAnimation(.snappy(duration: 0.35)) { theme = t }
                    } label: { swatch(t) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.displayName)
                    .accessibilityAddTraits(theme == t ? .isSelected : [])
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