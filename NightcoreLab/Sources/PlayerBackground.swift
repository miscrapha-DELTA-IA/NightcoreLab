import SwiftUI
import SDWebImageSwiftUI

// MARK: - Estilo do fundo

/// Estilos do fundo do mini-player. O botão de vinil avança ciclicamente por eles.
enum PlayerBackgroundStyle: Int, CaseIterable {
    /// Fosco: capa desfocada.
    case blurred
    /// Nítido: capa sem blur, com overlay mais forte para manter o texto legível.
    case sharp
    /// Em movimento: capa deslizando em loop contínuo.
    case marquee

    /// Próximo estilo no ciclo blurred → sharp → marquee → blurred.
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
        }
    }
}

// MARK: - Camadas de fundo

/// Fundo do mini-player: imagem + overlay escuro, conforme o `PlayerBackgroundStyle`.
/// Deve ser usado em `.background { }`, que dá a ele exatamente o tamanho do card;
/// o recorte nas bordas arredondadas é feito por quem o usa (`clipShape`).
struct PlayerBackgroundView: View {
    let style: PlayerBackgroundStyle
    let imageURL: URL

    var body: some View {
        ZStack {
            switch style {
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
            WebImage(url: url)
                .resizable()
                .transition(.fade(duration: 0.2))
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

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
        .onAppear(perform: startLoop)
        // Animações repeatForever podem parar depois que o app volta do segundo plano.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startLoop() }
        }
        .onChange(of: reduceMotion) { _, _ in startLoop() }
    }

    private func tile(in size: CGSize) -> some View {
        WebImage(url: url)
            .resizable()
            .transition(.fade(duration: 0.2))
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// Zera o offset sem animar e, no ciclo seguinte, liga o loop linear de 15 s.
    /// Com "Reduzir Movimento" ligado, a capa fica parada.
    private func startLoop() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { isAnimating = false }

        guard !reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}
