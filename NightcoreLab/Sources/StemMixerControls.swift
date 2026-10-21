import SwiftUI
import QuickLook

/// Controls the actual cached neural sources, never a proxy on the original mix.
struct StemMixerControls: View {
    let audio: AudioEngineManager
    @State private var previewURL: URL?
    @State private var showCloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("STEMS").font(.caption.bold()).tracking(1.2)
                Spacer()
                Button("Restaurar 100%") { audio.resetStemLevels() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("stem.reset")
            }
            Text("Separação real por IA")
                .font(.caption.weight(.semibold))
            if audio.isPreparingStems {
                Text(audio.stemPreparationTitle).font(.caption.weight(.semibold)).lineLimit(1)
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
                Text(audio.stemPreparationIsCloud
                     ? "Você pode trocar de música. O pedido e os downloads ficam salvos; ao voltar ao app, ele retoma o acompanhamento."
                     : "Você pode trocar de música. Em segundo plano, a separação pausa e retoma os trechos salvos ao voltar.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if audio.stemsAvailable {
                Label("\(audio.stemSource?.title ?? "IA") · stems salvos neste iPhone", systemImage: "checkmark.circle.fill")
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
                    Text("A separação no iPhone requer iOS 18 ou superior e o modelo incluído. A opção na nuvem usa internet.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No iPhone, a música fica no aparelho e funciona offline. Na nuvem, o áudio é enviado ao Hugging Face e há limite de uso gratuito.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !audio.stemPreparationMessage.isEmpty {
                    Text(audio.stemPreparationMessage).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !audio.isPreparingStems {
                Button {
                    showCloud = true
                } label: {
                    Label("Separar com GPU grátis", systemImage: "cloud")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!audio.hasStemSource || audio.isExporting)
                .accessibilityIdentifier("stem.prepareCloud")
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
                Text("A prévia local usa Demucs em um trecho próximo ao ponto da reprodução.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = audio.stemPreparationError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("stem.preparationError")
            }
            if audio.canResumeStemPreparation && !audio.isPreparingStems {
                Button("Retomar separação salva") { audio.resumeStemPreparation() }
                    .accessibilityIdentifier("stem.resume")
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
        .sheet(isPresented: $showCloud) {
            CloudStemStartView { code in audio.prepareCloudStems(code: code) }
        }
    }

    private func listen(to url: URL) {
        audio.pause()
        previewURL = url
    }
}
