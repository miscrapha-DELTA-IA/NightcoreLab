import SwiftUI

/// Ícone do Nightcore Lab: mascote felpudo monocromático cujo olho é um disco de vinil.
/// 100% formas geométricas. Quadrado e opaco: o iOS aplica a máscara arredondada sozinho.
struct AppIconView: View {

    // MARK: Paleta

    private let neon = Color(red: 0.2, green: 1.0, blue: 0.0)

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

    var body: some View {
        ZStack {
            Color.black

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

    // MARK: 2. Corpo felpudo

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

    // MARK: 3. Olho / vinil

    private var eye: some View {
        ZStack {
            // Pupila = disco
            Circle()
                .fill(.black)

            // Ranhuras
            ForEach(0..<14, id: \.self) { i in
                let diameter = 2 * (70 + CGFloat(i) * 10.5)
                Circle()
                    .stroke(.white.opacity(i.isMultiple(of: 4) ? 0.12 : 0.06), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
            }

            // Brilho suave nas ranhuras
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

            // Rótulo central
            Circle()
                .fill(Color(white: 0.09))
                .frame(width: 96, height: 96)
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 2))

            // Pino neon
            Circle()
                .fill(neon)
                .frame(width: 24, height: 24)
                .shadow(color: neon.opacity(0.9), radius: 10)
                .shadow(color: neon.opacity(0.6), radius: 24)

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

    // MARK: 4. Braço do toca-discos

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

            // Luz neon na agulha
            Circle()
                .fill(neon)
                .frame(width: 16, height: 16)
                .shadow(color: neon, radius: 8)
                .shadow(color: neon.opacity(0.6), radius: 20)
                .position(pointOnArm(1 + 22 / armLength))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 10, x: 6, y: 10)
    }

    // MARK: Utilitários

    private func point(on center: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
        let r = Angle.degrees(degrees).radians
        return CGPoint(x: center.x + radius * cos(r), y: center.y + radius * sin(r))
    }

    /// Pseudoaleatório determinístico (0…1): o ícone sai idêntico em toda renderização.
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

#Preview("Ícone 1024") {
    AppIconView()
        .scaleEffect(0.35)
        .frame(width: 360, height: 360)
}

#Preview("Com máscara do iOS") {
    AppIconView()
        .clipShape(RoundedRectangle(cornerRadius: 1024 * 0.2237, style: .continuous))
        .scaleEffect(0.18)
        .frame(width: 190, height: 190)
}
