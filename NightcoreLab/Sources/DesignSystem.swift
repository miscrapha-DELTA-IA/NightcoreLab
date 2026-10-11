import SwiftUI

// MARK: - Temas

/// Temas do Nightcore Lab: um único acento neon por tema sobre base preta OLED.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case acid, crimson, cyber
    // Os novos temas precisam compartilhar o rawValue com MarbleTheme.
    case ultraviolet, solar, orchid, sapphire
    case atomic, lagoon, volt, prism, magma, noir
    case ultrapink, ultraorange, purewhite, ultrablack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .acid:    return "Acid"
        case .crimson: return "Crimson"
        case .cyber:   return "Cyber"
        case .ultraviolet: return "Ultraviolet"
        case .solar:       return "Solar"
        case .orchid:      return "Orchid"
        case .sapphire:    return "Sapphire"
        case .atomic: return "Atomic"
        case .lagoon: return "Lagoon"
        case .volt: return "Volt"
        case .prism: return "Prism"
        case .magma: return "Magma"
        case .noir: return "Noir"
        case .ultrapink:   return "Ultrapink"
        case .ultraorange: return "Ultra Orange"
        case .purewhite:   return "Pure White"
        case .ultrablack:  return "Ultra Black"
        }
    }

    /// Cor dominante descrita no menu do botão de raio e no VoiceOver.
    var dominantColorName: String {
        switch self {
        case .acid:        return "verde neon"
        case .crimson:     return "vermelho sangue"
        case .cyber:       return "azul elétrico"
        case .ultraviolet: return "violeta azulado"
        case .solar:       return "amarelo âmbar"
        case .orchid:      return "roxo orquídea"
        case .sapphire:    return "azul safira"
        case .atomic: return "verde-azulado"
        case .lagoon: return "azul petróleo"
        case .volt: return "amarelo limão"
        case .prism: return "laranja vibrante"
        case .magma: return "laranja-fogo"
        case .noir: return "branco"
        case .ultrapink:   return "rosa neon"
        case .ultraorange: return "laranja neon"
        case .purewhite:   return "branco puro"
        case .ultrablack:  return "preto absoluto"
        }
    }

    /// Neon principal: botões ativos, barras, glow, pino do vinil.
    var accent: Color {
        switch self {
        case .acid:    return Color(red: 0.20, green: 1.00, blue: 0.00)   // #33FF00 verde neon
        case .crimson: return Color(red: 1.00, green: 0.12, blue: 0.24)   // #FF1F3D vermelho sangue
        case .cyber:   return Color(red: 0.18, green: 0.48, blue: 1.00)   // #2E7AFF azul cobalto elétrico
        case .ultraviolet: return Color(red: 0.61, green: 0.55, blue: 1.00) // #9C8CFF violeta azulado
        case .solar:       return Color(red: 1.00, green: 0.78, blue: 0.17) // #FFC72C amarelo âmbar
        case .orchid:      return Color(red: 0.83, green: 0.42, blue: 0.88) // #D46CE0 roxo orquídea
        case .sapphire:    return Color(red: 0.31, green: 0.42, blue: 1.00) // #4F6BFF azul safira
        case .atomic: return Color(red: 0.11, green: 0.79, blue: 0.72) // #1CC9B8 verde-azulado
        case .lagoon: return Color(red: 0.12, green: 0.61, blue: 0.88) // #1E9BE0 azul petróleo
        case .volt: return Color(red: 0.95, green: 0.88, blue: 0.00) // #F2E100 amarelo limão
        case .prism: return Color(red: 1.00, green: 0.54, blue: 0.12) // #FF8A1F laranja vibrante
        case .magma: return Color(red: 1.00, green: 0.35, blue: 0.16) // #FF5A2A laranja-fogo
        case .noir: return Color(red: 0.96, green: 0.96, blue: 0.96) // #F4F4F6 branco
        case .ultrapink:   return Color(red: 1.00, green: 0.18, blue: 0.65) // #FF2EA6 rosa neon
        case .ultraorange: return Color(red: 1.00, green: 0.29, blue: 0.10) // #FF4A1A laranja neon
        case .purewhite:   return Color(red: 1.00, green: 1.00, blue: 1.00) // #FFFFFF branco puro
        case .ultrablack:  return Color(red: 0.62, green: 0.64, blue: 0.69) // #9EA3AF cinza-aço (preto absoluto)
        }
    }

    /// Segunda cor do tema, para gradientes e luz ambiente.
    var secondary: Color {
        switch self {
        case .acid:    return Color(red: 0.00, green: 0.90, blue: 0.63)   // #00E5A0 verde-água
        case .crimson: return Color(red: 1.00, green: 0.36, blue: 0.12)   // #FF5C1F brasa
        case .cyber:   return Color(red: 0.00, green: 0.83, blue: 1.00)   // #00D4FF ciano
        case .ultraviolet: return Color(red: 0.79, green: 0.82, blue: 0.96) // #C9D1F5 prata arroxeado
        case .solar:       return Color(red: 1.00, green: 0.54, blue: 0.17) // #FF8A2B laranja
        case .orchid:      return Color(red: 0.91, green: 0.85, blue: 0.94) // #E8D8F0 lilás claro
        case .sapphire:    return Color(red: 0.66, green: 0.72, blue: 1.00) // #A8B8FF azul-pervinca
        case .atomic: return Color(red: 1.00, green: 0.35, blue: 0.21) // #FF5A36
        case .lagoon: return Color(red: 1.00, green: 0.75, blue: 0.18) // #FFC02E
        case .volt: return Color(red: 0.79, green: 0.79, blue: 0.83) // #C9CAD3
        case .prism: return Color(red: 0.18, green: 0.71, blue: 1.00) // #2FB6FF
        case .magma: return Color(red: 1.00, green: 0.69, blue: 0.18) // #FFB02E
        case .noir: return Color(red: 1.00, green: 0.17, blue: 0.17) // #FF2B2B
        case .ultrapink:   return Color(red: 1.00, green: 0.70, blue: 0.90) // #FFB3E6 rosa claro
        case .ultraorange: return Color(red: 0.79, green: 0.84, blue: 0.94) // #C9D6F0 branco azulado
        case .purewhite:   return Color(red: 0.68, green: 0.71, blue: 0.77) // #AEB6C4 prata
        case .ultrablack:  return Color(red: 0.48, green: 0.50, blue: 0.55) // #7A7F8C grafite
        }
    }

    /// Conteúdo sobre superfícies pintadas com o acento.
    /// Texto preto mantém pelo menos 4,5:1 de contraste em todos os temas (WCAG AA).
    var onAccent: Color { .black }

    /// Gradiente acento → secundária (barras dos sliders).
    func gradient(vertical: Bool = false) -> LinearGradient {
        LinearGradient(colors: [accent, secondary],
                       startPoint: vertical ? .bottom : .leading,
                       endPoint: vertical ? .top : .trailing)
    }

    /// Próximo tema na ordem de allCases; após Noir volta para Acid.
    var next: AppTheme {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

// MARK: - Tokens

enum DS {
    enum Radius {
        /// Campos e controles.
        static let control: CGFloat = 16
        /// Cartões médios (toggle de tom).
        static let medium: CGFloat = 20
        /// Trilho dos sliders.
        static let track: CGFloat = 22
        /// Cartões principais (música).
        static let card: CGFloat = 24
    }

    enum Spacing {
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 16
        static let l: CGFloat = 22
        static let xl: CGFloat = 28
    }

    enum Typography {
        /// Título do app.
        static let display = Font.system(size: 28, weight: .bold, design: .rounded)
        /// Rótulos de seção (sempre em caixa alta, com tracking).
        static let sectionLabel = Font.caption.weight(.semibold)
        /// Valores dos controles.
        static let value = Font.system(.title3, design: .rounded).weight(.semibold).monospacedDigit()
        static let valueCompact = Font.system(.headline, design: .rounded).weight(.semibold).monospacedDigit()
        static let trackTitle = Font.system(.headline, design: .rounded).weight(.semibold)
        static let body = Font.subheadline
        static let bodyStrong = Font.subheadline.weight(.semibold)
        static let caption = Font.caption
        /// Tempos e percentuais: dígitos de largura fixa, para não "dançarem".
        static let captionNumeric = Font.caption.monospacedDigit()
        static let subtitleNumeric = Font.subheadline.monospacedDigit()
    }

    enum Ink {
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.55)
        static let tertiary = Color.white.opacity(0.38)
        static let error = Color(red: 1.0, green: 0.45, blue: 0.40)
    }

    /// Período do glow pulsante, em segundos.
    static let pulseDuration: Double = 1.6
}

/// Fase 0…1 de um seno com período `DS.pulseDuration`.
/// Todas as superfícies leem o mesmo relógio, então pulsam em sincronia.
func pulsePhase(at date: Date) -> Double {
    let t = date.timeIntervalSinceReferenceDate
    return (sin(t * 2 * .pi / DS.pulseDuration) + 1) / 2
}

// MARK: - Rótulo de seção

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Typography.sectionLabel)
            .tracking(2)
            .foregroundStyle(DS.Ink.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Fundo ambiente

/// Preto OLED com duas luzes difusas na cor do tema. É o que o vidro refrata:
/// vidro sobre preto chapado vira uma mancha cinza sem profundidade.
struct AmbientBackground: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [theme.accent.opacity(0.20), .clear],
                           center: UnitPoint(x: 0.08, y: 0.04),
                           startRadius: 10, endRadius: 440)
            RadialGradient(colors: [theme.secondary.opacity(0.14), .clear],
                           center: UnitPoint(x: 0.98, y: 0.72),
                           startRadius: 10, endRadius: 400)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glow pulsante

/// Luz neon atrás de um elemento. Fica numa camada própria (background), nunca no
/// conteúdo: assim pulsar não recria a view (um TextField não perde o foco).
struct GlowPulse<S: Shape>: View {
    let shape: S
    let color: Color
    var isActive: Bool
    /// false = glow aceso, mas estático (ex.: preset selecionado).
    var pulses: Bool = true
    var intensity: Double = 1
    var blur: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isActive && pulses && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let phase = animates ? pulsePhase(at: context.date) : 0.5
            shape
                .fill(color)
                .blur(radius: blur)
                .opacity(isActive ? (0.22 + 0.33 * phase) * intensity : 0)
        }
        .animation(.easeInOut(duration: 0.35), value: isActive)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Vidro

/// Superfície de vidro do Nightcore Lab.
/// - iOS 26 (compilado com Xcode 26): Liquid Glass nativo (`.glassEffect`).
/// - iOS 17–25: `.ultraThinMaterial` + brilho de topo (overlay) + tingimento aditivo (plusLighter).
/// Em ambos: aresta em gradiente, sombra de elevação e glow pulsante quando ativo.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let theme: AppTheme
    var isActive: Bool = false
    var pulses: Bool = true
    var glowIntensity: Double = 1
    /// Multiplicador da sombra de elevação (0.4 para botões pequenos, 1 para cartões).
    var depth: Double = 1
    var interactive: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        glass(content)
            .overlay { rim }
            .background {
                GlowPulse(shape: shape, color: theme.accent, isActive: isActive,
                          pulses: pulses, intensity: glowIntensity)
            }
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if reduceTransparency {
                content.background { legacyGlass }
            } else {
                content
                    .glassEffect(
                        .regular
                            .tint(theme.accent.opacity(isActive ? 0.16 : 0.05))
                            .interactive(interactive),
                        in: shape
                    )
                // Sem .shadow aqui: o Liquid Glass já projeta a própria sombra adaptativa.
            }
        } else {
            content.background { legacyGlass }
        }
        #else
        content.background { legacyGlass }
        #endif
    }

    /// Vidro para iOS 17–25 (e fallback de Reduzir Transparência).
    @ViewBuilder
    private var legacyGlass: some View {
        if reduceTransparency {
            shape
                .fill(Color(white: 0.11))
                .shadow(color: .black.opacity(0.45 * depth), radius: 18 * depth, x: 0, y: 12 * depth)
        } else {
            ZStack {
                // Desfoca a luz ambiente que está atrás.
                shape
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.45 * depth), radius: 18 * depth, x: 0, y: 12 * depth)
                // Brilho de topo: a luz "bate" na borda superior do vidro.
                shape
                    .fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    .blendMode(.overlay)
                // Tingimento aditivo: acende o vidro com o neon sem lavar o preto.
                shape
                    .fill(theme.accent.opacity(isActive ? 0.10 : 0.035))
                    .blendMode(.plusLighter)
            }
        }
    }

    /// Aresta de vidro: branca no topo, na cor do tema embaixo. Pulsa junto com o glow.
    private var rim: some View {
        let animates = isActive && pulses && !reduceMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let phase = animates ? pulsePhase(at: context.date) : 0.5
            shape.strokeBorder(
                LinearGradient(colors: [
                    .white.opacity(0.28),
                    .white.opacity(0.05),
                    theme.accent.opacity(isActive ? 0.40 + 0.45 * phase : 0.14)
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Aplica a superfície de vidro do design system.
    func glassSurface<S: InsettableShape>(_ shape: S,
                                          theme: AppTheme,
                                          isActive: Bool = false,
                                          pulses: Bool = true,
                                          glowIntensity: Double = 1,
                                          depth: Double = 1,
                                          interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, theme: theme, isActive: isActive, pulses: pulses,
                              glowIntensity: glowIntensity, depth: depth, interactive: interactive))
    }
}

/// Agrupa elementos de vidro próximos. No iOS 26 vira um `GlassEffectContainer`
/// (um único passe de renderização e fusão entre as peças); antes disso, não faz nada.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Medidor de nível

/// Quatro barras que "dançam" enquanto a música toca (decorativo).
struct LevelBars: View {
    let color: Color
    let isAnimating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isAnimating && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animates)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    let i = Double(index)
                    let level = animates ? 0.25 + 0.75 * abs(sin(t * (2.3 + i * 0.7) + i * 1.3)) : 0.22
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 22 * level)
                }
            }
            .frame(height: 22, alignment: .bottom)
        }
        .opacity(isAnimating ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.3), value: isAnimating)
        .accessibilityHidden(true)
    }
}
