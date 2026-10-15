import SwiftUI

/// Native-gain stem controls live in Música, not Criar or Legenda.
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
            Text(audio.stemsAvailable
                 ? "Faixas espectrais preparadas · ajuste ao vivo"
                 : "EQ instantânea · preparando faixas espectrais locais")
                .font(.caption2).foregroundStyle(.secondary)
            if !audio.stemsAvailable {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Preparando faixas")
            }
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
            Text("Separação espectral aproximada: instrumentos podem compartilhar frequências.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("music.stemMixer")
        .onAppear { audio.requestStemPreparation() }
    }
}
