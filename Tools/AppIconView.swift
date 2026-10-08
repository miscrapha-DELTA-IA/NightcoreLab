import SwiftUI

/// Ícone do Nightcore Lab desenhado 100% com formas geométricas.
/// Quadrado e opaco: o iOS aplica a máscara arredondada sozinho, então não arredonde os cantos.
struct AppIconView: View {

    // MARK: Geometria (canvas de 1024 × 1024)

    private let canvas: CGFloat = 1024

    private let recordCenter = CGPoint(x: 460, y: 570)
    private let recordRadius: CGFloat = 370

    private let pivot = CGPoint(x: 850, y: 190)          // base do braço, fora do disco
    private var stylus: CGPoint {                        // ponto onde a agulha toca o disco
        let angle = Angle.degrees(28).radians
        let r = recordRadius * 0.72
        return CGPoint(x: recordCenter.x + r * cos(angle),
                       y: recordCenter.y + r * sin(angle))
    }

    private var armVector: CGVector { CGVector(dx: stylus.x - pivot.x, dy: stylus.y - pivot.y) }
    private var armLength: CGFloat { hypot(armVector.dx, armVector.dy) }
    private var armAngle: Angle { .radians(atan2(armVector.dy, armVector.dx)) }
    private var armDirection: CGVector { CGVector(dx: armVector.dx / armLength, dy: armVector.dy / armLength) }

    /// Ponto ao longo do braço: 0 = pivô, 1 = agulha (valores fora de 0…1 extrapolam).
    private func pointOnArm(_ t: CGFloat) -> CGPoint {
        CGPoint(x: pivot.x + armVector.dx * t, y: pivot.y + armVector.dy * t)
    }

    // MARK: Paleta

    private let metalLight = Color(white: 0.86)
    private let metalDark = Color(white: 0.52)
    private let graphite = Color(white: 0.11)

    var body: some View {
        ZStack {
            background
            record
            tonearm
        }
        .frame(width: canvas, height: canvas)
        .clipped()
    }

    // MARK: 1. Fundo

    private var background: some View {
        RadialGradient(colors: [Color(white: 0.10), Color(white: 0.035), .black],
                       center: UnitPoint(x: recordCenter.x / canvas, y: recordCenter.y / canvas),
                       startRadius: 40, endRadius: 760)
    }

    // MARK: 2. Disco de vinil

    private var record: some View {
        ZStack {
            // Corpo do disco
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.07), Color(white: 0.025)],
                                     center: .center, startRadius: 0, endRadius: recordRadius))
                .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 2))
                .shadow(color: .black.opacity(0.7), radius: 40, y: 24)

            // Sulcos concêntricos
            ForEach(0..<15, id: \.self) { i in
                let diameter = 2 * (150 + CGFloat(i) * 14.5)
                Circle()
                    .stroke(.white.opacity(i.isMultiple(of: 4) ? 0.075 : 0.035), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
            }

            // Brilho da luz refletida nos sulcos (duas faixas opostas)
            Circle()
                .fill(AngularGradient(stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .white.opacity(0.07), location: 0.09),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.50),
                    .init(color: .white.opacity(0.05), location: 0.59),
                    .init(color: .clear, location: 0.68),
                    .init(color: .clear, location: 1.00)
                ], center: .center, angle: .degrees(-30)))
                .padding(18)

            // Rótulo central
            Circle()
                .fill(graphite)
                .frame(width: 210, height: 210)
                .overlay(Circle().stroke(.pink.opacity(0.85), lineWidth: 5).padding(14))
                .overlay(Circle().stroke(.white.opacity(0.06), lineWidth: 2))

            // Eixo
            Circle()
                .fill(LinearGradient(colors: [metalLight, metalDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
        }
        .frame(width: recordRadius * 2, height: recordRadius * 2)
        .position(recordCenter)
    }

    // MARK: 3. Braço e cápsula

    private var tonearm: some View {
        ZStack {
            // Contrapeso, atrás do pivô
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 2))
                .frame(width: 120, height: 84)
                .rotationEffect(armAngle)
                .position(pointOnArm(-0.22))

            // Haste do braço
            Capsule()
                .fill(LinearGradient(colors: [metalLight, metalDark], startPoint: .top, endPoint: .bottom))
                .frame(width: armLength * 0.98, height: 20)
                .rotationEffect(armAngle)
                .position(pointOnArm(0.49))

            // Base do pivô com anel ciano
            Circle()
                .fill(graphite)
                .frame(width: 176, height: 176)
                .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 2))
                .position(pivot)

            Circle()
                .stroke(.cyan, lineWidth: 7)
                .frame(width: 128, height: 128)
                .shadow(color: .cyan.opacity(0.9), radius: 18)
                .position(pivot)

            Circle()
                .fill(LinearGradient(colors: [metalLight, metalDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 78, height: 78)
                .position(pivot)

            Circle()
                .fill(graphite)
                .frame(width: 22, height: 22)
                .position(pivot)

            // Headshell (suporte da cápsula)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 2))
                .frame(width: 128, height: 62)
                .rotationEffect(armAngle)
                .position(pointOnArm(1 - 40 / armLength))

            // Faixa rosa na frente da cápsula
            Rectangle()
                .fill(.pink)
                .frame(width: 14, height: 62)
                .shadow(color: .pink.opacity(0.9), radius: 14)
                .rotationEffect(armAngle)
                .position(pointOnArm(1 + 18 / armLength))

            // Agulha tocando o disco: ponto rosa com halo
            Circle()
                .fill(.pink.opacity(0.25))
                .frame(width: 70, height: 70)
                .blur(radius: 14)
                .position(pointOnArm(1 + 30 / armLength))

            Circle()
                .fill(.white)
                .frame(width: 12, height: 12)
                .shadow(color: .pink, radius: 10)
                .position(pointOnArm(1 + 30 / armLength))

            // LED ciano no braço
            Circle()
                .fill(.cyan)
                .frame(width: 10, height: 10)
                .shadow(color: .cyan, radius: 8)
                .position(pointOnArm(0.30))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.65), radius: 22, x: 14, y: 20)
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
