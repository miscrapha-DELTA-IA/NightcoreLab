import SwiftUI

enum ObjectWordMaterial: String, CaseIterable, Sendable {
    case vinylSticker, dymoTicket, liquidCapsule
}

/// Stable, testable physical parameters. Both live Karaoke and Story pass the
/// same TypographyWordFrame seed and progress into this resolver.
struct ObjectWordAppearance: Equatable, Sendable {
    let material: ObjectWordMaterial
    let rotation: Double
    let borderWidth: Double
    let shadowRadius: Double
    let shadowX: Double
    let shadowY: Double
    let fontVariant: Int
    let fill: Double
}

enum ObjectWordStyleResolver {
    static func resolve(style: TypographyStyle, seed: UInt64,
                        progress: Double) -> ObjectWordAppearance? {
        guard let material = ObjectWordMaterial(rawValue: style.rawValue) else { return nil }
        let tilt = Double(seed & 0xffff) / Double(UInt16.max) * 2 - 1
        let variant = Int((seed >> 24) & 1)
        let fill = progress.isFinite ? min(1, max(0, progress)) : 0
        switch material {
        case .vinylSticker:
            return .init(material: material, rotation: tilt * 3.2,
                         borderWidth: 3, shadowRadius: 9,
                         shadowX: 2, shadowY: 7, fontVariant: variant, fill: fill)
        case .dymoTicket:
            return .init(material: material, rotation: tilt * 1.4,
                         borderWidth: 1.5, shadowRadius: 0,
                         shadowX: 4, shadowY: 5, fontVariant: variant, fill: fill)
        case .liquidCapsule:
            return .init(material: material, rotation: tilt * 1.2,
                         borderWidth: 1.8, shadowRadius: 13,
                         shadowX: 0, shadowY: 8, fontVariant: variant, fill: fill)
        }
    }
}

struct DymoTicketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notch = min(5, rect.height * 0.15)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + notch, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + notch))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - notch))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - notch))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + notch))
            path.closeSubpath()
        }
    }
}

/// The substrate and ink are drawn twice by KaraokeWordView; its leading mask
/// reveals the filled object at the exact source-time word progress.
struct ObjectWordTile: View {
    let text: String
    let appearance: ObjectWordAppearance
    let accent: Color
    let fontSize: CGFloat
    let maxWordWidth: CGFloat
    let minimumScaleFactor: CGFloat
    let filled: Bool

    private var label: some View {
        Text(appearance.material == .dymoTicket ? text.uppercased() : text)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(minimumScaleFactor)
            .frame(maxWidth: maxWordWidth)
    }

    private var font: Font {
        switch appearance.material {
        case .vinylSticker:
            return .system(size: fontSize * (appearance.fontVariant == 0 ? 0.96 : 0.89),
                           weight: .black, design: appearance.fontVariant == 0 ? .rounded : .default)
        case .dymoTicket:
            return .system(size: fontSize * 0.84, weight: .heavy,
                           design: appearance.fontVariant == 0 ? .monospaced : .default)
        case .liquidCapsule:
            return .system(size: fontSize * 0.91,
                           weight: appearance.fontVariant == 0 ? .bold : .semibold, design: .rounded)
        }
    }

    @ViewBuilder var body: some View {
        switch appearance.material {
        case .vinylSticker:
            label
                .foregroundStyle(filled ? Color.black : .white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? accent : Color.black.opacity(0.94)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: CGFloat(appearance.borderWidth)))
                .shadow(color: .black.opacity(0.75), radius: CGFloat(appearance.shadowRadius),
                        x: CGFloat(appearance.shadowX), y: CGFloat(appearance.shadowY))
        case .dymoTicket:
            label
                .foregroundStyle(filled ? Color.black : Color.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(DymoTicketShape().fill(filled ? accent : Color(white: 0.12)))
                .overlay(DymoTicketShape().stroke(Color.white.opacity(0.76),
                                                  lineWidth: CGFloat(appearance.borderWidth)))
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.17)).frame(height: 2)
                        .padding(.horizontal, 9).padding(.top, 3)
                }
                .shadow(color: .black.opacity(0.85), radius: CGFloat(appearance.shadowRadius),
                        x: CGFloat(appearance.shadowX), y: CGFloat(appearance.shadowY))
        case .liquidCapsule:
            label
                .foregroundStyle(.white)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(filled ? accent.opacity(0.68) : Color.black.opacity(0.78)))
                .overlay(Capsule().strokeBorder(accent.opacity(filled ? 1 : 0.76),
                                                lineWidth: CGFloat(appearance.borderWidth)))
                .overlay(alignment: .top) {
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.27), .clear],
                                                  startPoint: .top, endPoint: .bottom))
                        .frame(height: 11).padding(.horizontal, 5).padding(.top, 2)
                }
                .shadow(color: accent.opacity(filled ? 0.42 : 0.18),
                        radius: CGFloat(appearance.shadowRadius),
                        x: CGFloat(appearance.shadowX), y: CGFloat(appearance.shadowY))
        }
    }
}
