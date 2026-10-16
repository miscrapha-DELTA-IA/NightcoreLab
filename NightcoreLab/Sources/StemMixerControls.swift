import SwiftUI

/// Native-gain stem controls live in Música, not Criar or Legenda.
struct StemMixerControls: View {
    let audio: AudioEngineManager
    @AppStorage("stems.devBackendEnabled") private var devBackend = false
    @AppStorage("stems.devBackendURL") private var devURL = ""
    @State private var devToken = ""
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
                 ? (audio.stemSource == .demucs
                    ? "4 fontes Demucs isoladas · ajuste ao vivo"
                    : "4 faixas STFT aproximadas · ajuste ao vivo")
                 : "Preparando 4 faixas independentes · música original preservada")
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
            DisclosureGroup("Separação real · Modo DEV") {
                Toggle("Usar servidor Demucs (envia áudio)", isOn: $devBackend)
                    .accessibilityIdentifier("stem.devBackend")
                if devBackend {
                    TextField("https://servidor-local-ou-dev", text: $devURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Token do servidor", text: $devToken)
                        .onChange(of: devToken) { _, new in StemDevCredentials.save(new) }
                    Text("Requer backend com htdemucs instalado e STEMS_DEV_ENABLED=1. O áudio só é enviado quando você ativa esta opção e prepara uma nova faixa.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Text(audio.stemSource == .demucs
                 ? "Modelo Demucs: saídas independentes, alinhadas na mesma linha do tempo."
                 : "Modo local: máscaras STFT são estimativas; ainda pode haver vazamento entre instrumentos.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("music.stemMixer")
        .onAppear {
            devToken = StemDevCredentials.load() ?? ""
            audio.requestStemPreparation()
        }
    }
}
