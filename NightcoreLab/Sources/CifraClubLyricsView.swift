import SwiftUI

/// Compact controls above the karaoke scroll surface. The chord above each
/// word is painted by KaraokeLineView without changing its measured height.
struct CifraClubLyricsView: View {
    let placements: [ChordPlacement]
    let dna: SongDNA?
    let clock: PlaybackClock
    let accent: Color
    @Binding var transpose: Int
    @Binding var simplify: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let time = clock.lyricTime
            let current = placements.last { $0.time <= time }?.chord
            let upcoming = placements.first { $0.time > time }?.chord
            let capo = current.map { ChordProgressionResolver.capoSuggestion(
                for: $0, transpose: transpose) } ?? 0
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("Tom: \(current?.transposed(transpose, simplify: simplify) ?? dna?.keyName ?? "—")")
                        .font(.caption.weight(.bold))
                    Button("−½") { transpose -= 1 }
                    Button("+½") { transpose += 1 }
                    Button(simplify ? "Simples ✓" : "Simplificar") { simplify.toggle() }
                    Text("Capo \(capo)ª").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(accent)
                HStack(spacing: 8) {
                    Text("Batida")
                        .font(.caption2.weight(.semibold))
                    let active = ChordProgressionResolver.strumIndex(
                        at: time, beats: dna?.beatTimestamps ?? [])
                    ForEach(ChordProgressionResolver.strumArrows.indices, id: \.self) { index in
                        Text(ChordProgressionResolver.strumArrows[index])
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(active == index ? accent : .white.opacity(0.42))
                    }
                    Spacer(minLength: 0)
                    if let current {
                        MiniChordDiagram(name: current.transposed(transpose - capo,
                                                                   simplify: simplify))
                    }
                    if let upcoming, upcoming != current {
                        MiniChordDiagram(name: upcoming.transposed(transpose - capo,
                                                                    simplify: simplify))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("karaoke.cifraControls")
        }
    }
}

private struct MiniChordDiagram: View {
    let name: String
    private static let shapes: [String: [Int]] = [
        "C": [-1, 3, 2, 0, 1, 0], "G": [3, 2, 0, 0, 0, 3],
        "D": [-1, -1, 0, 2, 3, 2], "A": [-1, 0, 2, 2, 2, 0],
        "E": [0, 2, 2, 1, 0, 0], "F": [1, 3, 3, 2, 1, 1],
        "Am": [-1, 0, 2, 2, 1, 0], "Em": [0, 2, 2, 0, 0, 0],
        "Dm": [-1, -1, 0, 2, 3, 1]
    ]
    var body: some View {
        VStack(spacing: 1) {
            Text(name).font(.caption2.bold())
            if let frets = Self.shapes[name] {
                Canvas { context, size in
                    for string in 0..<6 {
                        let x = size.width * CGFloat(string) / 5
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 2))
                        path.addLine(to: CGPoint(x: x, y: size.height - 2))
                        context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 0.7)
                        if frets[string] > 0 {
                            let y = size.height * (CGFloat(frets[string]) - 0.5) / 4
                            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5,
                                                                  width: 5, height: 5)),
                                         with: .color(.white))
                        }
                    }
                    for fret in 0...4 {
                        let y = size.height * CGFloat(fret) / 4
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(.white.opacity(0.5)),
                                       lineWidth: fret == 0 ? 1.4 : 0.7)
                    }
                }
                .frame(width: 31, height: 27)
            }
        }
        .accessibilityLabel("Diagrama de \(name)")
    }
}
