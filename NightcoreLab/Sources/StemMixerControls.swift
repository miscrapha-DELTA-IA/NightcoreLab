import SwiftUI

/// Four instant, phase-preserving masking controls in Música.
struct StemMixerControls: View {
    let audio: AudioEngineManager

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("STEMS").font(.caption.bold()).tracking(1.2)
                Spacer()
                Button("Restaurar 100%") { audio.resetStemLevels() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("stem.reset")
            }
            Text("Ajuste instantâneo ao vivo · sem preparar a música")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(StemKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(kind.title).font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(Int((audio.stemLevels[kind] ?? 1) * 100))%")
                            .font(.caption.monospacedDigit())
                    }
                    Slider(value: Binding(
                        get: { Double(audio.stemLevels[kind] ?? 1) },
                        set: { audio.setStemLevel(kind, level: Float($0)) }),
                        in: 0...2)
                        .accessibilityIdentifier("stem.level.\(kind.rawValue)")
                }
            }
            Text("Máscaras locais aproximadas. Algumas frequências e instrumentos podem se sobrepor.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("music.stemMixer")
    }
}
