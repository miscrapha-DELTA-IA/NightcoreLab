import SwiftUI

/// Native-gain stem controls live in Música, not Criar or Legenda.
struct StemMixerControls: View {
    let audio: AudioEngineManager
    @AppStorage("stems.devBackendEnabled") private var devBackend = false
    @AppStorage("stems.devBackendURL") private var devURL = ""
    @State private var devToken = ""
    @State private var isCheckingConnection = false
    @State private var connectionFeedback: String?
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
                 : "Prepare os stems quando quiser · música original preservada")
                .font(.caption2).foregroundStyle(.secondary)
            if let status = audio.stemPreparationStatus {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("stem.preparationStatus")
            } else if let message = audio.stemPreparationError {
                Text(message)
                    .font(.caption2).foregroundStyle(.red)
                    .accessibilityIdentifier("stem.preparationError")
            }
            if !audio.stemsAvailable {
                Button("Preparar stems") { audio.requestStemPreparation() }
                    .disabled(audio.stemPreparationStatus != nil)
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
                        .onChange(of: devToken) { _, new in
                            StemDevCredentials.save(new)
                            connectionFeedback = nil
                        }
                    Text(devToken.trimmingCharacters(in: .whitespacesAndNewlines).count == 64
                         ? "Token salvo no iPhone (64 caracteres)."
                         : "Token ainda não confirmado no iPhone.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button {
                        isCheckingConnection = true
                        connectionFeedback = "Testando túnel e autenticação…"
                        Task { @MainActor in
                            do { connectionFeedback = try await DevStemBackend.verifyConfiguration() }
                            catch { connectionFeedback = error.localizedDescription }
                            isCheckingConnection = false
                        }
                    } label: {
                        Label("Testar conexão e token · sem enviar música",
                              systemImage: "checkmark.shield")
                    }
                    .disabled(isCheckingConnection || audio.stemPreparationStatus != nil)
                    .accessibilityIdentifier("stem.testConnection")
                    if let connectionFeedback {
                        Text(connectionFeedback)
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("stem.connectionResult")
                    }
                    Text("O áudio da faixa atual é enviado apenas quando você tocar Preparar com Demucs. Use a URL HTTPS do túnel e o token local gerado pelo instalador.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    audio.retryStemPreparation()
                } label: {
                    Label(devBackend ? "Preparar com Demucs" : "Reprocessar stems locais",
                          systemImage: "waveform.path")
                }
                .buttonStyle(.borderedProminent)
                .disabled(audio.stemPreparationStatus != nil)
                .accessibilityIdentifier("stem.retryPreparation")
                if audio.stemPreparationStatus != nil {
                    Button("Cancelar espera no iPhone") { audio.cancelStemPreparation() }
                        .font(.caption2)
                        .accessibilityIdentifier("stem.cancelPreparation")
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
        }
    }
}
