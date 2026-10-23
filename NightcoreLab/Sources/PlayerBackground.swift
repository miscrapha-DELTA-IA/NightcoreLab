import SwiftUI

// MARK: - Estilo do fundo

/// Estilos visíveis no menu de fundo do cartão principal.
enum PlayerBackgroundStyle: Int, CaseIterable, Sendable {
    /// Fosco: capa desfocada.
    case blurred
    /// Nítido: capa sem blur, com overlay mais forte para manter o texto legível.
    case sharp
    /// Em movimento: capa deslizando em loop contínuo.
    case marquee
    /// Turbulent Displacement: textura líquida Metal, compartilhada com o Story.
    case turbulent

    /// Próximo estilo no ciclo blurred → sharp → marquee → turbulent → blurred.
    var next: PlayerBackgroundStyle {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var displayName: String {
        switch self {
        case .blurred: return "Fosco"
        case .sharp:   return "Nítido"
        case .marquee: return "Em movimento"
        case .turbulent: return "Turbulent Displacement"
        }
    }

    var symbolName: String {
        switch self {
        case .blurred: return "circle.dotted"
        case .sharp: return "photo"
        case .marquee: return "arrow.left.and.right"
        case .turbulent: return "waveform.path"
        }
    }
}

// MARK: - Camadas de fundo

/// Fundo do mini-player: imagem + overlay escuro, conforme o `PlayerBackgroundStyle`.
/// Deve ser usado em `.background { }`, que dá a ele exatamente o tamanho do card;
/// o recorte nas bordas arredondadas é feito por quem o usa (`clipShape`).
struct PlayerBackgroundView: View {
    let style: PlayerBackgroundStyle
    let imageURL: URL?
    let theme: AppTheme
    var sourceClock: PlaybackClock? = nil
    var sourceDuration: TimeInterval = 0
    var artworkHue: Double? = nil
    var frozenTime: Float? = nil
    var isPaused: Bool = false
    var reactiveDistortion: Double = 0
    var pulseDriver: MarblePulseDriver? = nil
    var material: VisualMaterial = .legacyMarble
    var liveMeter: AudioVisualLiveMeter? = nil
    var reactionMode: CreativePreset.AudioReaction = .off
    var sectionCadence: SongSectionCadence = .neutral
    var creatorControls: CreatorControls = .neutral
    var padAccentEmitter: PadVisualAccentEmitter? = nil

    /// The on-screen palette/uniform route is identical to full-screen
    /// TurbulentMarbleView, not an independent Cyber Night theme switch.
    var resolvedMaterial: VisualMaterial { material }
    var renderedSurface: MarbleSurfaceBinding {
        MarbleSurfaceBinding.resolve(material: resolvedMaterial)
    }
    var effectiveStyle: PlayerBackgroundStyle {
        renderedSurface.textured ? .turbulent : style
    }

    var body: some View {
        ZStack {
            if effectiveStyle == .turbulent {
                // O modo fluido do cartão usa o mesmo shader Metal do fundo
                // principal; frame pacing follows EnergyBudget and thermal limits.
                TurbulentMarbleView(
                    theme: MarbleTheme(appTheme: theme),
                    sourceClock: sourceClock, sourceDuration: sourceDuration,
                    artworkHue: artworkHue,
                    speed: 0.6,
                    maxFPS: 60,
                    isPaused: isPaused,
                    extendIntoSafeArea: false,
                    frozenTime: frozenTime,
                    reactiveDistortion: reactiveDistortion,
                    material: resolvedMaterial,
                    pulseDriver: frozenTime == nil ? pulseDriver : nil,
                    liveMeter: frozenTime == nil ? liveMeter : nil,
                    reactionMode: reactionMode,
                    sectionCadence: sectionCadence,
                    creatorControls: creatorControls,
                    padAccentEmitter: padAccentEmitter
                )
                // Preserve legacy readability while allowing authored
                // high-contrast five-stop surfaces to remain recognizable.
                .overlay(Color.black.opacity(
                    material.parameters.usesProceduralTexture ? 0.30 : 0.4))
            } else if let imageURL {
                switch effectiveStyle {
                case .blurred:
                ZStack {
                    CoverFill(url: imageURL)
                        .blur(radius: 15, opaque: true)
                    Color.black.opacity(0.4)
                }
                .transition(.opacity)

            case .sharp:
                ZStack {
                    CoverFill(url: imageURL)
                    Color.black.opacity(0.6)
                }
                .transition(.opacity)

                case .marquee:
                    ZStack {
                        MarqueeCover(url: imageURL)
                        Color.black.opacity(0.5)
                    }
                    .transition(.opacity)
                case .turbulent:
                    EmptyView() // Renderizado acima; mantém o switch exaustivo.
                }
            } else {
                Color.black.opacity(0.34)
            }
        }
        .clipped()
    }
}

/// Imagem preenchendo todo o espaço proposto (`scaledToFill`), sem vazar do quadro.
private struct CoverFill: View {
    let url: URL

    var body: some View {
        GeometryReader { geometry in
            PlayerArtworkImage(url: url) { image in
                if let image { image.resizable().scaledToFill() }
                else { GnarlyArtworkPlaceholder() }
            }
                .transition(.opacity)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(GnarlyArtworkPlaceholder())
                .clipped()
        }
    }
}

/// Duas cópias idênticas da capa lado a lado deslizando para a esquerda em loop linear.
/// Quando a primeira cópia sai por completo, o offset volta a 0 e a segunda ocupa o lugar dela.
///
/// O estado de animação vive nesta subview (e não no card) de propósito: ao trocar de estilo,
/// a subview é destruída e recriada, então o `isAnimating` sempre começa em `false` e o
/// `onAppear` dispara o loop de novo. Se o estado morasse no pai, ele continuaria `true`
/// na segunda visita e a animação não recomeçaria.
private struct MarqueeCover: View {
    let url: URL

    @State private var isAnimating = false
    @Environment(\.energyBudget) private var energyBudget

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                tile(in: geometry.size)
                tile(in: geometry.size)
            }
            .frame(width: geometry.size.width * 2, height: geometry.size.height, alignment: .leading)
            .offset(x: isAnimating ? -geometry.size.width : 0)
        }
        .clipped()
        .task(id: energyBudget.allowsDecorativeMotion) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { isAnimating = false }
            guard energyBudget.allowsDecorativeMotion else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: 15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }

    private func tile(in size: CGSize) -> some View {
        PlayerArtworkImage(url: url) { image in
            if let image { image.resizable().scaledToFill() }
            else { GnarlyArtworkPlaceholder() }
        }
            .transition(.opacity)
            .frame(width: size.width, height: size.height)
            .background(GnarlyArtworkPlaceholder())
            .clipped()
    }

}
