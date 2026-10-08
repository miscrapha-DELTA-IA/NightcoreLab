import SwiftUI

/// Mascote do Nightcore Lab: monstro felpudo monocromático de um olho só, derretendo na base.
/// O olho é um disco de vinil com o braço de um toca-discos apoiado nele; o pino central
/// e a agulha acendem na cor do tema.
///
/// - Desenhado num canvas de 1024 × 1024 e escalado para qualquer tamanho
///   (36 pt no cabeçalho, 1024 px para exportar o ícone).
/// - Exportar o ícone: `ImageRenderer(content: AppIconView(theme: .acid).frame(width: 1024, height: 1024))`
///   com `scale = 1`. Quadrado e opaco: o iOS aplica a máscara arredondada sozinho.
struct AppIconView: View {
    var theme: AppTheme = .acid
    /// false = sem o quadrado preto (para usar sobre o fundo do app).
    var showsBackground: Bool = true
    /// true = o disco gira e as luzes pulsam (música tocando).
    var isPlaying: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Geometria (canvas de 1024 × 1024)

    private let canvas: CGFloat = 1024

    private let bodyCenter = CGPoint(x: 500, y: 470)
    private let bodyRadius: CGFloat = 320

    private var eyeCenter: CGPoint { CGPoint(x: bodyCenter.x, y: bodyCenter.y - 4) }
    private let eyeRadius: CGFloat = 222

    private let tuftCount = 46
    /// Faixa na base sem pelos: é onde o corpo "derrete".
    private let meltArc: ClosedRange<Double> = 55...125

    /// Gotas que escorrem da base: deslocamento horizontal, largura e comprimento.
    private let dripSpecs: [(dx: CGFloat, width: CGFloat, length: CGFloat)] = [
        (-95, 46, 105),
        (-10, 58, 150),
        (78, 40, 80)
    ]

    private let pivot = CGPoint(x: 862, y: 232)
    /// A agulha repousa perto da borda do disco preto, no quadrante inferior direito.
    private var stylus: CGPoint { point(on: eyeCenter, radius: eyeRadius - 24, degrees: 30) }

    private var neon: Color { theme.accent }
    private var animates: Bool { isPlaying && !reduceMotion }

    // MARK: Corpo da view

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            artwork
                .frame(width: canvas, height: canvas)
                .scaleEffect(side / canvas)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var artwork: some View {
        ZStack {
            if showsBackground {
                Color.black
            }

            fur
            Circle()
                .fill(.white)
                .frame(width: bodyRadius * 2, height: bodyRadius * 2)
                .position(bodyCenter)
            drips

            eye
            tonearm
        }
        .frame(width: canvas, height: canvas)
        .clipped()
    }

    // MARK: 1. Corpo felpudo

    /// Tufos ao redor do círculo: espinhos (polígonos curvos) intercalados com cápsulas,
    /// com tamanho e ângulo levemente irregulares para quebrar a simetria.
    private var fur: some View {
        ZStack {
            ForEach(0..<tuftCount, id: \.self) { i in
                let degrees = Double(i) / Double(tuftCount) * 360 + Double(noise(i, 1) - 0.5) * 6
                if !meltArc.contains(degrees) {
                    tuft(index: i, degrees: degrees)
                }
            }
        }
    }

    private func tuft(index i: Int, degrees: Double) -> some View {
        let length = 48 + noise(i, 2) * 52
        let width = 44 + noise(i, 3) * 26
        let center = point(on: bodyCenter, radius: bodyRadius + length * 0.5 - 26, degrees: degrees)

        return Group {
            if i.isMultiple(of: 3) {
                Capsule()
                    .fill(.white)
                    .frame(width: width * 1.25, height: length * 0.75)
            } else {
                FurSpike()
                    .fill(.white)
                    .frame(width: width, height: length)
            }
        }
        .rotationEffect(.degrees(degrees + 90))   // ponta apontando para fora
        .position(center)
    }

    /// Escorridos na base, cada um terminando numa gota, mais duas gotas soltas.
    private var drips: some View {
        let bottom = bodyCenter.y + bodyRadius

        return ZStack {
            ForEach(dripSpecs.indices, id: \.self) { i in
                let spec = dripSpecs[i]
                let x = bodyCenter.x + spec.dx

                Capsule()
                    .fill(.white)
                    .frame(width: spec.width, height: spec.length + 60)
                    .position(x: x, y: bottom - 60 + (spec.length + 60) / 2)

                Circle()
                    .fill(.white)
                    .frame(width: spec.width * 1.3, height: spec.width * 1.3)
                    .position(x: x, y: bottom + spec.length - spec.width * 0.3)
            }

            Circle()
                .fill(.white)
                .frame(width: 40, height: 40)
                .position(x: bodyCenter.x - 185, y: bottom + 115)

            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .position(x: bodyCenter.x + 150, y: bottom + 62)
        }
    }

    // MARK: 2. Olho / vinil

    private var eye: some View {
        ZStack {
            // Pupila = disco
            Circle()
                .fill(.black)

            // Ranhuras concêntricas (escuras, quase invisíveis)
            ForEach(0..<14, id: \.self) { i in
                let diameter = 2 * (70 + CGFloat(i) * 10.5)
                Circle()
                    .stroke(.white.opacity(i.isMultiple(of: 4) ? 0.12 : 0.06), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
            }

            // Reflexo nas ranhuras: gira como um disco a 33⅓ rpm quando a música toca
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
                let degrees = animates
                    ? (context.date.timeIntervalSinceReferenceDate * 200).truncatingRemainder(dividingBy: 360)
                    : 0
                Circle()
                    .fill(AngularGradient(stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .white.opacity(0.06), location: 0.10),
                        .init(color: .clear, location: 0.20),
                        .init(color: .clear, location: 0.50),
                        .init(color: .white.opacity(0.04), location: 0.60),
                        .init(color: .clear, location: 0.70),
                        .init(color: .clear, location: 1.00)
                    ], center: .center, angle: .degrees(-35)))
                    .padding(14)
                    .rotationEffect(.degrees(degrees))
            }

            // Rótulo central, com um anel fino na cor do tema
            Circle()
                .fill(Color(white: 0.09))
                .frame(width: 96, height: 96)
                .overlay(Circle().stroke(neon.opacity(0.35), lineWidth: 3).padding(10))
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 2))

            // Pino central aceso
            neonLight(diameter: 24, glow: 10, wideGlow: 24)

            // Reflexo do olho (canto superior esquerdo)
            Circle()
                .fill(.white)
                .frame(width: 70, height: 70)
                .offset(x: -92, y: -92)
            Circle()
                .fill(.white)
                .frame(width: 24, height: 24)
                .offset(x: -40, y: -132)
        }
        .frame(width: eyeRadius * 2, height: eyeRadius * 2)
        .position(eyeCenter)
    }

    // MARK: 3. Braço do toca-discos

    private var armVector: CGVector { CGVector(dx: stylus.x - pivot.x, dy: stylus.y - pivot.y) }
    private var armLength: CGFloat { hypot(armVector.dx, armVector.dy) }
    private var armAngle: Angle { .radians(atan2(armVector.dy, armVector.dx)) }

    /// Ponto ao longo do braço: 0 = pivô, 1 = agulha (fora de 0…1 extrapola).
    private func pointOnArm(_ t: CGFloat) -> CGPoint {
        CGPoint(x: pivot.x + armVector.dx * t, y: pivot.y + armVector.dy * t)
    }

    private var tonearm: some View {
        let metal = LinearGradient(colors: [Color(white: 0.82), Color(white: 0.52)],
                                   startPoint: .top, endPoint: .bottom)

        return ZStack {
            // Contrapeso
            Capsule()
                .fill(Color(white: 0.22))
                .overlay(Capsule().stroke(.white.opacity(0.85), lineWidth: 5))
                .frame(width: 92, height: 64)
                .rotationEffect(armAngle)
                .position(pointOnArm(-0.17))

            // Haste: contorno preto para destacar sobre o corpo branco
            Capsule()
                .fill(metal)
                .overlay(Capsule().stroke(.black, lineWidth: 4))
                .frame(width: armLength * 0.98, height: 20)
                .rotationEffect(armAngle)
                .position(pointOnArm(0.49))

            // Base do pivô
            Circle()
                .fill(Color(white: 0.14))
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 6))
                .frame(width: 124, height: 124)
                .position(pivot)
            Circle()
                .fill(metal)
                .frame(width: 54, height: 54)
                .position(pivot)

            // Cápsula (headshell)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(white: 0.55))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.black, lineWidth: 4))
                .frame(width: 96, height: 50)
                .rotationEffect(armAngle)
                .position(pointOnArm(1 - 30 / armLength))

            // Laser da agulha, na cor do tema
            neonLight(diameter: 16, glow: 8, wideGlow: 20)
                .position(pointOnArm(1 + 22 / armLength))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 10, x: 6, y: 10)
    }

    // MARK: Luz neon

    /// Ponto de luz na cor do tema. Pulsa quando a música toca.
    private func neonLight(diameter: CGFloat, glow: CGFloat, wideGlow: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let phase = animates ? pulsePhase(at: context.date) : 0.6
            Circle()
                .fill(neon)
                .frame(width: diameter, height: diameter)
                .shadow(color: neon.opacity(0.6 + 0.4 * phase), radius: glow)
                .shadow(color: neon.opacity(0.35 + 0.35 * phase), radius: wideGlow * (0.8 + 0.4 * phase))
        }
    }

    // MARK: Utilitários

    private func point(on center: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
        let r = Angle.degrees(degrees).radians
        return CGPoint(x: center.x + radius * cos(r), y: center.y + radius * sin(r))
    }

    /// Pseudoaleatório determinístico (0…1): o mascote sai idêntico em toda renderização.
    private func noise(_ i: Int, _ salt: Double) -> CGFloat {
        let x = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return CGFloat(x - floor(x))
    }
}

/// Tufo de pelo: triângulo com laterais curvas e ponta levemente torta.
private struct FurSpike: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY),
                          control: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

#Preview("Três temas") {
    HStack(spacing: 16) {
        ForEach(AppTheme.allCases) { theme in
            AppIconView(theme: theme)
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 110 * 0.2237, style: .continuous))
        }
    }
    .padding()
    .background(Color(white: 0.15))
}

#Preview("Tocando (cabeçalho)") {
    AppIconView(theme: .cyber, showsBackground: false, isPlaying: true)
        .frame(width: 160, height: 160)
        .padding()
        .background(Color.black)
}
