import SwiftUI

// MARK: - Modelo de Passo do Onboarding

struct GnarlyOnboardingStep: Identifiable {
    let id: Int
    let tag: String
    let title: String
    let subtitle: String
    let icon: String
    let accentColor: Color
    let highlights: [String]
}

// MARK: - View Principal de Onboarding

struct GnarlyOnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    private let steps: [GnarlyOnboardingStep] = [
        GnarlyOnboardingStep(
            id: 0,
            tag: "PASSO 01 · MÚSICA",
            title: "Busca & Cache Offline",
            subtitle: "Pesquise qualquer faixa ou cole um link. O Gnarly prepara o áudio em segundo plano e mantém seu Mix salvo para tocar sem internet.",
            icon: "magnifyingglass",
            accentColor: Color(red: 0.0, green: 0.90, blue: 1.0),
            highlights: [
                "Busca rápida + sugestões automáticas no Descobrir",
                "Download paralelo com indicador de progresso em tempo real",
                "Fila inteligente que preserva suas músicas offline"
            ]
        ),
        GnarlyOnboardingStep(
            id: 1,
            tag: "PASSO 02 · KARAOKÊ",
            title: "Letras & Combo de Voz",
            subtitle: "O player sobe para o topo e abre o palco. Acompanhe a letra sincronizada ou ative o microfone para pontuar sua afinação e ritmo.",
            icon: "mic.fill",
            accentColor: Color(red: 0.71, green: 1.0, blue: 0.0),
            highlights: [
                "Sincronia limpa com ajuste rápido na aba Legenda",
                "Modo Ligar Mic: pontuação ao vivo e multiplicador de combo",
                "Gravação integrada na barra superior para compartilhar"
            ]
        ),
        GnarlyOnboardingStep(
            id: 2,
            tag: "PASSO 03 · DSP & VELOCIDADE",
            title: "Nightcore, Slowed & Stems",
            subtitle: "Controle total sobre a física do som em tempo real. Acelere até 1.73x+, isole vocais com Stems ou mergulhe a faixa em Reverb.",
            icon: "slider.horizontal.3",
            accentColor: Color(red: 1.0, green: 0.45, blue: 0.85),
            highlights: [
                "Presets instantâneos: Redefinir, Lentidão e Nightcore",
                "Chave 'Manter o tom original' ou pitch dinâmico em cents",
                "Sliders dedicados de Velocidade, Reverb (%), Baixo (dB) e Stems"
            ]
        ),
        GnarlyOnboardingStep(
            id: 3,
            tag: "PASSO 04 · ESTÉTICA",
            title: "Temas, Materiais & Zen",
            subtitle: "Toque no raio (⚡) para alternar entre paletas puras, texturas materiais ou os shaders autônomos do Gnarly.",
            icon: "bolt.fill",
            accentColor: Color(red: 1.0, green: 0.75, blue: 0.20),
            highlights: [
                "Clássicos & Materiais: Ultrapink, Xerox Serpentine, Prism Carmine",
                "Modos Autônomos: Gnarly, Gnarly · Strata e Gnarly · Compiler",
                "Ritmo Visual (Fluido/Reativo) + Ícone de Olho para ocultar a UI"
            ]
        )
    ]

    var body: some View {
        ZStack {
            // Scrim escuro sobre o shader ativo do app
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Barra Superior do Onboarding
                HStack {
                    Text("GNARLY // TOUR RÁPIDO")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.6))

                    Spacer()

                    Button {
                        dismissOnboarding()
                    } label: {
                        Text("Pular")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                // Carrossel de 4 Passos
                TabView(selection: $currentPage) {
                    ForEach(steps) { step in
                        OnboardingStepCard(step: step)
                            .tag(step.id)
                            .padding(.horizontal, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(duration: 0.45, bounce: 0.15), value: currentPage)

                // Rodapé: Indicadores + Botão de Ação
                VStack(spacing: 18) {
                    // Indicadores em pílula
                    HStack(spacing: 8) {
                        ForEach(steps) { step in
                            Capsule()
                                .fill(currentPage == step.id ? steps[currentPage].accentColor : .white.opacity(0.22))
                                .frame(width: currentPage == step.id ? 28 : 8, height: 8)
                                .animation(.spring(duration: 0.35), value: currentPage)
                        }
                    }

                    // Botão Principal
                    Button {
                        if currentPage < steps.count - 1 {
                            withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
                                currentPage += 1
                            }
                        } else {
                            dismissOnboarding()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(currentPage < steps.count - 1 ? "Próximo" : "Entrar no Gnarly")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Image(systemName: currentPage < steps.count - 1 ? "arrow.right" : "sparkles")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(steps[currentPage].accentColor, in: Capsule())
                        .shadow(color: steps[currentPage].accentColor.opacity(0.45), radius: 14, y: 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: currentPage)
    }

    private func dismissOnboarding() {
        withAnimation(.easeOut(duration: 0.25)) {
            isPresented = false
        }
    }
}

// MARK: - Card Individual com Mockup HUD

private struct OnboardingStepCard: View {
    let step: GnarlyOnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 8)

            // Mockup visual da funcionalidade (estilo HUD do app)
            stepVisualPreview
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [step.accentColor.opacity(0.65), .white.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )

            // Tag + Ícone
            HStack(spacing: 8) {
                Image(systemName: step.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(step.accentColor, in: Circle())

                Text(step.tag)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(step.accentColor)
            }

            // Título & Subtítulo
            VStack(alignment: .leading, spacing: 8) {
                Text(step.title)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text(step.subtitle)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Lista de Destaques
            VStack(alignment: .leading, spacing: 10) {
                ForEach(step.highlights, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(step.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)

                        Text(item)
                            .font(.system(size: 13.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var stepVisualPreview: some View {
        switch step.id {
        case 0:
            // Preview 1: Barra de Busca + Preparando Música 87%
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(step.accentColor)
                    Text("Buscar música · Mix 15 · Offline")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.45), in: Capsule())

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preparando música...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text("87%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(step.accentColor)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule()
                                .fill(step.accentColor)
                                .frame(width: geo.size.width * 0.87)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(12)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(20)

        case 1:
            // Preview 2: Karaokê + HUD de Combo
            VStack(spacing: 12) {
                HStack {
                    Label("Ligar mic", systemImage: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(step.accentColor.opacity(0.22), in: Capsule())
                        .foregroundStyle(step.accentColor)

                    Spacer()

                    Text("1x · 0 combo")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: Capsule())
                }

                VStack(spacing: 4) {
                    Text("Sailing and shoring")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Dancing the beta can-can")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(step.accentColor)
                }
                .padding(.top, 4)
            }
            .padding(20)

        case 2:
            // Preview 3: Speed & Pitch 1.73x + Stems
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("Speed & Pitch", systemImage: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.18), in: Capsule())

                    Label("Stems", systemImage: "slider.vertical.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.07), in: Capsule())
                }

                HStack {
                    Text("VELOCIDADE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("1.73×")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, step.accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 28)
                    .overlay(alignment: .trailing) {
                        Capsule()
                            .fill(.white)
                            .frame(width: 4, height: 18)
                            .padding(.trailing, 14)
                    }
            }
            .padding(20)

        default:
            // Preview 4: Seletor de Temas e Modos Gnarly
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(step.accentColor)
                    Text("TEMAS · MATERIAIS & AUTÔNOMOS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }

                ForEach(["Xerox Serpentine", "Prism Carmine", "Gnarly · Strata"], id: \.self) { themeName in
                    HStack {
                        Text(themeName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Spacer()
                        Circle()
                            .strokeBorder(step.accentColor, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
    }
}