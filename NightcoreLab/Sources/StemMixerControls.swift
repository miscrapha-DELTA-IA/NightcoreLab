import SwiftUI
import QuickLook

/// Controls the actual cached neural sources, never a proxy on the original mix.
struct StemMixerControls: View {
    let audio: AudioEngineManager
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("STEMS").font(.caption.bold()).tracking(1.2)
                Spacer()
                Button("Restaurar 100%") { audio.resetStemLevels() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("stem.reset")
            }
            Text("Separação real por IA · no iPhone")
                .font(.caption.weight(.semibold))
            if audio.isPreparingStems {
                ProgressView(value: audio.stemPreparationProgress) {
                    Text(audio.stemPreparationMessage).font(.caption)
                }
                .accessibilityIdentifier("stem.preparationProgress")
                HStack {
                    Text("\(Int(audio.stemPreparationProgress * 100))%")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button(audio.isCancellingStems ? "Cancelando…" : "Cancelar") { audio.cancelStemPreparation() }
                        .font(.caption.weight(.semibold))
                        .disabled(audio.isCancellingStems)
                }
                Text("Mantenha o app aberto. O tempo varia conforme a música e o iPhone.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if audio.stemsAvailable {
                Label("Demucs · stems salvos neste iPhone", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
                HStack(spacing: 12) {
                    Button("Sem voz") { audio.applyStemPreset(.karaoke) }
                    Button("Só voz") { audio.applyStemPreset(.acapella) }
                    Button("Ritmo") { audio.applyStemPreset(.rhythm) }
                }
                .font(.caption.weight(.semibold))
            } else {
                Button {
                    audio.prepareNeuralStemPreview()
                } label: {
                    Label("Gerar prévia de 8 segundos", systemImage: "ear")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!audio.hasStemSource || !audio.hasNeuralStemModel || audio.isExporting)
                .accessibilityIdentifier("stem.preparePreview")
                Button {
                    audio.prepareNeuralStems()
                } label: {
                    Label("Separar música", systemImage: "waveform.path")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!audio.hasStemSource || !audio.hasNeuralStemModel || audio.isExporting)
                .accessibilityIdentifier("stem.prepareNeural")
                if !audio.hasStemSource {
                    Text("Escolha uma música para separar voz, bateria, baixo e outros instrumentos.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !audio.hasNeuralStemModel {
                    Text("A separação neural requer iOS 18 ou superior e a versão do app com o modelo incluído.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("A música fica no aparelho. A separação funciona sem conta e sem internet.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !audio.stemPreparationMessage.isEmpty {
                    Text(audio.stemPreparationMessage).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let asset = audio.stemPreview, let preview = asset.preview {
                Text("Compare a prévia antes de separar a música inteira.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Original") { listen(to: preview.originalURL) }
                    Button("Só voz") { if let url = asset.vocalURL { listen(to: url) } }
                    Button("Sem voz") { listen(to: preview.accompanimentURL) }
                }
                .font(.caption.weight(.semibold))
                Text("A prévia usa um trecho próximo ao ponto da reprodução e o mesmo modelo da separação completa.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = audio.stemPreparationError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("stem.preparationError")
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
                        set: { audio.setStemLevel(kind, level: Float($0)) }), in: 0...2)
                        .disabled(!audio.stemsAvailable)
                        .accessibilityIdentifier("stem.level.\(kind.rawValue)")
                }
                .opacity(audio.stemsAvailable ? 1 : 0.45)
            }
        }
        .accessibilityIdentifier("music.stemMixer")
        .quickLookPreview($previewURL)
    }

    private func listen(to url: URL) {
        audio.pause()
        previewURL = url
    }
}
