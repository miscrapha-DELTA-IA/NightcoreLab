import SwiftUI

// MARK: - Temas

enum MarbleTheme: String, CaseIterable, Identifiable {
    case acid, cyber, crimson
    var id: String { rawValue }

    /// deep = veios/sombras · body = corpo do líquido · glow = brilho/acento
    var palette: (deep: Color, body: Color, glow: Color) {
        switch self {
        case .acid:    // verde neon / preto / amarelo
            return (Color(red: 0.00, green: 0.12, blue: 0.03),
                    Color(red: 0.10, green: 0.85, blue: 0.10),
                    Color(red: 0.85, green: 1.00, blue: 0.25))
        case .cyber:   // ciano / magenta / roxo profundo
            return (Color(red: 0.10, green: 0.02, blue: 0.22),
                    Color(red: 0.00, green: 0.90, blue: 1.00),
                    Color(red: 1.00, green: 0.10, blue: 0.80))
        case .crimson: // vermelho sangue / laranja / preto
            return (Color(red: 0.03, green: 0.00, blue: 0.00),
                    Color(red: 0.75, green: 0.03, blue: 0.08),
                    Color(red: 1.00, green: 0.45, blue: 0.05))
        }
    }
}

extension MarbleTheme {
    /// Bind the shader palette to the application's existing saved theme.
    init(appTheme: AppTheme) {
        self = MarbleTheme(rawValue: appTheme.rawValue) ?? .acid
    }
}

// MARK: - View

/// Fundo animado. Use como primeira camada do ZStack principal.
struct TurbulentMarbleView: View {
    var theme: MarbleTheme = .acid
    var speed: Double = 1.0          // 0.5 = mais calmo (e mais bonito atrás de letras)
    var maxFPS: Double = 60          // use 30 em Low Power Mode
    var isPaused: Bool = false
    var extendIntoSafeArea: Bool = true

    @State private var start = Date()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = theme.palette
        TimelineView(.animation(minimumInterval: 1.0 / max(maxFPS, 1.0),
                                paused: isPaused || reduceMotion || scenePhase != .active)) { ctx in
            let t = Float((isPaused || reduceMotion ? 0 : ctx.date.timeIntervalSince(start)) * speed)
            Rectangle()
                .fill(.black)
                .visualEffect { content, proxy in
                    content.colorEffect(
                        ShaderLibrary.liquidMarble(
                            .float2(proxy.size),
                            .float(t),
                            .color(p.deep), .color(p.body), .color(p.glow)
                        )
                    )
                }
        }
        .id(theme)                                  // troca de tema = crossfade
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.6), value: theme)
        .ignoresSafeArea(edges: extendIntoSafeArea ? .all : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Exemplo de integração

#Preview {
    ZStack {
        TurbulentMarbleView(theme: .acid)
        Color.black.opacity(0.35)                   // scrim: garante contraste do karaokê
        Text("Nightcore Lab").font(.largeTitle.bold()).foregroundStyle(.white)
    }
}