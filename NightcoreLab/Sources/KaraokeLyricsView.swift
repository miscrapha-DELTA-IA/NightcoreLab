import SwiftUI

// MARK: - Temas

struct KaraokeTheme: Equatable {
    var inactive: Color      // texto ainda não cantado
    var fill: Color          // cor do preenchimento
    var glow: Color          // brilho da palavra ativa
    var pastOpacity: Double  // linhas já cantadas
    var font: Font

    private static let base = Font.system(size: 30, weight: .heavy, design: .rounded)

    static let acid = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.71, green: 1.00, blue: 0.00),
        glow: Color(red: 0.71, green: 1.00, blue: 0.00).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let cyber = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.00, green: 0.94, blue: 1.00),
        glow: Color(red: 1.00, green: 0.00, blue: 0.80).opacity(0.65),
        pastOpacity: 0.55, font: base)

    static let crimson = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.16, blue: 0.30),
        glow: Color(red: 1.00, green: 0.16, blue: 0.30).opacity(0.7),
        pastOpacity: 0.55, font: base)

    static let ultraviolet = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.72, green: 0.67, blue: 1.00),
        glow: Color(red: 0.61, green: 0.55, blue: 1.00).opacity(0.70),
        pastOpacity: 0.55, font: base)

    // Fundo amarelo pede preenchimento creme para manter legibilidade.
    static let solar = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.93, blue: 0.62),
        glow: Color(red: 1.00, green: 0.78, blue: 0.17).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let orchid = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.94, green: 0.60, blue: 0.97),
        glow: Color(red: 0.83, green: 0.42, blue: 0.88).opacity(0.70),
        pastOpacity: 0.55, font: base)

    static let sapphire = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.62, green: 0.72, blue: 1.00),
        glow: Color(red: 0.31, green: 0.42, blue: 1.00).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let atomic = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.35, green: 0.95, blue: 0.88),
        glow: Color(red: 0.95, green: 0.30, blue: 0.18).opacity(0.70),
        pastOpacity: 0.55, font: base)

    static let lagoon = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.62, green: 0.85, blue: 1.00),
        glow: Color(red: 0.12, green: 0.65, blue: 0.95).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let volt = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.97, blue: 0.55),
        glow: Color(red: 0.95, green: 0.88, blue: 0.05).opacity(0.80),
        pastOpacity: 0.55, font: base)

    static let prism = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.82, blue: 0.55),
        glow: Color(red: 1.00, green: 0.54, blue: 0.12).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let magma = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.86, blue: 0.62),
        glow: Color(red: 1.00, green: 0.40, blue: 0.08).opacity(0.80),
        pastOpacity: 0.55, font: base)

    static let noir = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: .white,
        glow: Color(red: 1.00, green: 0.15, blue: 0.15).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let ultrapink = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.62, blue: 0.86),
        glow: Color(red: 1.00, green: 0.18, blue: 0.65).opacity(0.75),
        pastOpacity: 0.55, font: base)

    /// Preenchimento pêssego para legibilidade sobre o branco azulado.
    static let ultraorange = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.78, blue: 0.62),
        glow: Color(red: 1.00, green: 0.29, blue: 0.10).opacity(0.80),
        pastOpacity: 0.55, font: base)

    static let purewhite = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: .white,
        glow: Color.white.opacity(0.55),
        pastOpacity: 0.55, font: base)

    static let ultrablack = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: .white,
        glow: Color(red: 0.62, green: 0.64, blue: 0.69).opacity(0.45),
        pastOpacity: 0.55, font: base)
}

extension KaraokeTheme {
    static func forAppTheme(_ appTheme: AppTheme) -> KaraokeTheme {
        switch appTheme {
        case .acid: return .acid
        case .cyber: return .cyber
        case .crimson: return .crimson
        case .ultraviolet: return .ultraviolet
        case .solar: return .solar
        case .orchid: return .orchid
        case .sapphire: return .sapphire
        case .atomic: return .atomic
        case .lagoon: return .lagoon
        case .volt: return .volt
        case .prism: return .prism
        case .magma: return .magma
        case .noir: return .noir
        case .ultrapink: return .ultrapink
        case .ultraorange: return .ultraorange
        case .purewhite: return .purewhite
        case .ultrablack: return .ultrablack
        }
    }
}

// MARK: - Safe-area geometry

/// Keeps artwork fully framed and lyric glyphs away from narrow-screen edges.
/// Pure geometry, independent from the playback clock or LRCLIB pipeline.
enum KaraokeLayoutMetrics {
    static func horizontalInset(for width: CGFloat) -> CGFloat {
        min(44, max(28, width * 0.09))
    }

    static func textWidth(for width: CGFloat) -> CGFloat {
        max(1, width - horizontalInset(for: width) * 2)
    }

    static func fontSize(for width: CGFloat) -> CGFloat {
        min(28, max(22, width * 0.067))
    }

    static func verticalMargin(for height: CGFloat) -> CGFloat {
        min(120, max(48, height * 0.18))
    }

    static func coverEdge(for viewport: CGSize) -> CGFloat {
        max(1, min(520, viewport.width - 80, viewport.height * 0.56))
    }
}

// MARK: - View raiz

struct KaraokeLyricsView: View {
    @Environment(LyricsStore.self) private var store
    let clock: PlaybackClock
    var theme: KaraokeTheme = .acid
    var accent: Color? = nil

    var body: some View {
        GeometryReader { viewport in
            let inset = KaraokeLayoutMetrics.horizontalInset(for: viewport.size.width)
            let wordLimit = KaraokeLayoutMetrics.textWidth(for: viewport.size.width)
            let fittedTheme: KaraokeTheme = {
                var adjusted = theme
                adjusted.font = .system(
                    size: KaraokeLayoutMetrics.fontSize(for: viewport.size.width),
                    weight: .heavy, design: .rounded
                )
                return adjusted
            }()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(store.lines) { line in
                            KaraokeLineView(
                                line: line,
                                status: status(of: line),
                                isPlaying: store.isPlaying,
                                offset: store.userOffset,
                                clock: clock,
                                theme: fittedTheme,
                                accent: accent,
                                maxWordWidth: wordLimit
                            )
                            .id(line.id)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { store.seekHandler?(line.start) }
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .scrollIndicators(.hidden)
                .contentMargins(.vertical,
                                KaraokeLayoutMetrics.verticalMargin(for: viewport.size.height),
                                for: .scrollContent)
                .onChange(of: store.activeLineIndex) { _, new in
                    guard let new else { return }
                    withAnimation(.smooth(duration: 0.45)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .onAppear { store.startTracking() }
        .onDisappear { store.stopTracking() }
    }

    private func status(of line: TimedLyricLine) -> KaraokeLineView.Status {
        guard let a = store.activeLineIndex else { return .upcoming }
        return line.id < a ? .past : (line.id == a ? .active : .upcoming)
    }
}

// MARK: - Linha

/// Só a linha ATIVA (modo .word) contém TimelineView. As demais são estáticas,
/// então por frame só ~5-10 palavras recalculam, não a letra inteira.
private struct KaraokeLineView: View {
    enum Status: Equatable { case past, active, upcoming }

    let line: TimedLyricLine
    let status: Status
    let isPlaying: Bool
    let offset: TimeInterval
    let clock: PlaybackClock
    let theme: KaraokeTheme
    let accent: Color?
    let maxWordWidth: CGFloat

    var body: some View {
        if line.words.isEmpty {
            Color.clear.frame(height: 14)                   // pausa instrumental
        } else if status == .active && line.precision == .word {
            TimelineView(.animation(paused: !isPlaying)) { _ in
                let t = clock.lyricTime + offset            // lido direto do engine, a cada frame
                layout { $0.progress(at: t) }
            }
        } else {
            layout { _ in
                switch status {
                case .past: return 1
                case .active: return 1        // .line precision: acende a linha inteira, sem fingir
                case .upcoming: return 0
                }
            }
            .scaleEffect(status == .upcoming ? 0.96 : 1.0)
            .animation(.smooth(duration: 0.3), value: status)
        }
    }

    private func layout(fill: @escaping (WordSync) -> Double) -> some View {
        FlowLayout(lineSpacing: 6) {
            ForEach(line.words) { w in
                KaraokeWordView(
                    word: w,
                    fill: fill(w),
                    fillColor: status == .past ? (accent ?? theme.fill).opacity(theme.pastOpacity) : (accent ?? theme.fill),
                    glow: status == .active,
                    theme: theme,
                    maxWordWidth: maxWordWidth
                )
                .gapAfter(w.spaceAfter ? 9 : 0)
            }
        }
    }
}

// MARK: - Palavra: máscara exata da esquerda p/ direita

private struct KaraokeWordView: View {
    let word: WordSync
    let fill: Double          // 0...1, calculado de start/end reais
    let fillColor: Color
    let glow: Bool
    let theme: KaraokeTheme
    let maxWordWidth: CGFloat

    /// One line per word. Long words shrink instead of spilling outside the viewport.
    /// Both copies share the exact same metrics, preserving left-to-right sync.
    private var glyph: some View {
        Text(word.text)
            .font(theme.font)
            .lineLimit(1)
            .minimumScaleFactor(0.52)
            .frame(maxWidth: maxWordWidth)
    }

    var body: some View {
        glyph
            .foregroundStyle(theme.inactive)
            .overlay(alignment: .leading) {
                if fill > 0 {
                    glyph
                        .foregroundStyle(fillColor)
                        .mask(alignment: .leading) {
                            Rectangle().scaleEffect(x: fill, y: 1, anchor: .leading)
                        }
                        .shadow(color: glow ? theme.glow : .clear, radius: glow ? 10 : 0)
                }
            }
    }
}

// MARK: - FlowLayout (quebra de linha por palavra; sílabas coladas não quebram)

struct GapAfter: LayoutValueKey { static let defaultValue: CGFloat = 0 }
extension View {
    func gapAfter(_ v: CGFloat) -> some View { layoutValue(key: GapAfter.self, value: v) }
}

struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 6

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        var cursor: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            // Prefer a break at a space. When a joined syllable group gets too
            // long for the screen, an emergency break prevents horizontal overflow.
            if !rows[rows.count - 1].items.isEmpty, cursor + size.width > maxWidth {
                rows.append(Row()); cursor = 0
            }
            rows[rows.count - 1].items.append((i, size))
            rows[rows.count - 1].width = cursor + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            cursor += size.width + sub[GapAfter.self]
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = rows(maxWidth: proposal.width ?? .infinity, subviews)
        let h = r.reduce(0) { $0 + $1.height } + CGFloat(max(r.count - 1, 0)) * lineSpacing
        return CGSize(width: proposal.width ?? (r.map(\.width).max() ?? 0), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(maxWidth: bounds.width, subviews) {
            var x = bounds.minX + max(0, (bounds.width - row.width) / 2) // never start offscreen
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + subviews[item.index][GapAfter.self]
            }
            y += row.height + lineSpacing
        }
    }
}