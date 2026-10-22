import SwiftUI
import QuickLook

/// One Stems workflow; choosing cloud never changes the validated on-device
/// HTDemucs processing path or submits an inference without explicit consent.
private enum StemComputeLocation: String, CaseIterable, Identifiable {
    case iphone, huggingFace
    var id: String { rawValue }
    var title: String { self == .iphone ? "Neste iPhone" : "Hugging Face" }
}

/// Controls the actual cached neural sources, never a proxy on the original mix.
struct StemMixerControls: View {
    let audio: AudioEngineManager
    @State private var previewURL: URL?
    @State private var showDiscard = false
    @State private var showCloudConsent = false
    @State private var computeLocation: StemComputeLocation = .iphone
    @State private var gpuStatus: CloudStemWorker.Status?
    @State private var gpuStatusMessage: String?
    @State private var isCheckingGPU = false
    @State private var betaCode = ""
    @State private var hfToken = ""
    @State private var accountStatus: String?
    @State private var checkingAccount = false

    private var cloudNeedsCode: Bool { gpuStatus?.requires_beta_code == true }
    private var cloudCodeValid: Bool {
        !cloudNeedsCode || betaCode.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16
    }
    private var canStartSelected: Bool {
        guard audio.hasStemSource, !audio.isExporting, !audio.isPreparingStems,
              !audio.canResumeStemPreparation else { return false }
        if computeLocation == .iphone { return audio.hasNeuralStemModel }
        return !isCheckingGPU && gpuStatus?.isReady == true && cloudCodeValid && !checkingAccount
    }

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
            } else {
                if audio.stemsAvailable {
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
                    .disabled(!audio.hasStemSource || !audio.hasNeuralStemModel || audio.isExporting ||
                              audio.canResumeStemPreparation)
                    .accessibilityIdentifier("stem.preparePreview")
                }

                Picker("Processamento", selection: $computeLocation) {
                    ForEach(StemComputeLocation.allCases) { location in
                        Text(location.title).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("stem.computeLocation")

                if computeLocation == .iphone {
                    Text("HTDemucs · sem envio de áudio · qualidade local preservada. O tempo depende deste iPhone.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !audio.hasNeuralStemModel {
                        Text("A separação local requer iOS 18 ou superior e o modelo incluído.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    cloudDetails
                }

                Button {
                    if computeLocation == .iphone {
                        audio.prepareNeuralStems()
                    } else {
                        showCloudConsent = true
                    }
                } label: {
                    Label(computeLocation == .iphone ? "Separar música" : "Separar via Hugging Face",
                          systemImage: computeLocation == .iphone ? "waveform.path" : "cloud")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartSelected)
                .accessibilityIdentifier(computeLocation == .iphone ? "stem.prepareNeural" : "stem.prepareCloud")

                if !audio.hasStemSource {
                    Text("Escolha uma música para separar voz, bateria, baixo e outros instrumentos.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if audio.canResumeStemPreparation {
                    Text("Existe uma separação salva. Retome-a ou descarte-a antes de iniciar outra.")
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
                Button("Descartar tarefa salva", role: .destructive) { showDiscard = true }
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
        .task(id: computeLocation) {
            guard computeLocation == .huggingFace else {
                gpuStatus = nil; gpuStatusMessage = nil; isCheckingGPU = false
                return
            }
            isCheckingGPU = true
            gpuStatus = nil
            gpuStatusMessage = nil
            do {
                let status = try await CloudStemWorker.checkStatus()
                guard !Task.isCancelled else { return }
                gpuStatus = status
                gpuStatusMessage = status.statusMessage
            } catch {
                guard !Task.isCancelled else { return }
                gpuStatusMessage = error.localizedDescription
            }
            isCheckingGPU = false
        }
        .onAppear {
            betaCode = CloudStemBetaCode.read()
            hfToken = HuggingFaceAccess.read()
            if !hfToken.isEmpty { accountStatus = "Conta Hugging Face configurada neste iPhone" }
        }
        .confirmationDialog("Enviar áudio ao Hugging Face?", isPresented: $showCloudConsent,
                            titleVisibility: .visible) {
            Button("Confirmar envio à GPU") {
                guard gpuStatus?.isReady == true, canStartSelected else { return }
                let code = betaCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard CloudStemBetaCode.save(code) else {
                    gpuStatusMessage = "Não foi possível salvar o código do beta."
                    return
                }
                audio.prepareCloudStems(code: code)
            }
            Button("Manter no iPhone", role: .cancel) {}
        } message: {
            Text("O áudio será enviado ao Space público do Hugging Face para " +
                 "\(gpuStatus?.modelTitle ?? "GPU") e os quatro stems serão baixados. " +
                 "Fila e cota são limitadas; cancelar pode não interromper o trabalho remoto. " +
                 "Os dados temporários ficam sujeitos à retenção do provedor. " +
                 "Nenhuma solicitação ocorre até a confirmação.")
        }
        .confirmationDialog("Descartar a tarefa salva?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Descartar tarefa", role: .destructive) { audio.discardSavedStemPreparation() }
        } message: {
            Text("Os arquivos parciais da nuvem serão descartados. Um processamento já iniciado no serviço pode continuar e consumir sua cota.")
        }
    }

    @ViewBuilder
    private var cloudDetails: some View {
        if isCheckingGPU {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Conferindo GPU gratuita (sem enviar música)…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let status = gpuStatus, status.isReady {
            Label(status.modelTitle, systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            if status.usesDifferentModel {
                Text("Esta GPU comunitária usa BS-Roformer, não o HTDemucs do iPhone. " +
                     "A qualidade e o resultado podem ser diferentes. " +
                     "O HTDemucs remoto aparecerá aqui quando um Space próprio estiver validado.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Mesmo modelo HTDemucs da opção local, executado em GPU remota.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let message = gpuStatusMessage {
            Text(message).font(.caption2)
                .foregroundStyle(gpuStatus?.isReady == true ? Color.secondary : Color.orange)
                .accessibilityIdentifier("stem.cloudStatus")
        }
        if !isCheckingGPU {
            Button("Verificar GPU novamente") {
                Task { await refreshGPUStatus() }
            }
            .font(.caption2)
            .disabled(isCheckingGPU)
            .accessibilityIdentifier("stem.refreshCloudStatus")
        }
        if cloudNeedsCode {
            SecureField("Código de acesso do beta", text: $betaCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("stem.betaCode")
            if !cloudCodeValid {
                Text("Digite o código do beta fornecido pelo operador.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        if gpuStatus?.provider == "community_bs_roformer" {
            DisclosureGroup("Conta Hugging Face (opcional)") {
                Text("O acesso anônimo é permitido. Um token Read pessoal gratuito pode usar sua cota; nunca será enviado ao Render.")
                    .font(.caption2).foregroundStyle(.secondary)
                SecureField("Token Read · hf_…", text: $hfToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("stem.hfToken")
                HStack {
                    Button(checkingAccount ? "Verificando…" : "Verificar e salvar token") {
                        checkingAccount = true
                        accountStatus = nil
                        let token = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in
                            defer { checkingAccount = false }
                            do {
                                let profile = try await HuggingFaceAccess.verify(token)
                                guard HuggingFaceAccess.save(token) else {
                                    accountStatus = "Não foi possível salvar o token."; return
                                }
                                accountStatus = "Conta gratuita conectada: " + profile.name
                            } catch { accountStatus = error.localizedDescription }
                        }
                    }.disabled(checkingAccount || hfToken.isEmpty)
                    if !hfToken.isEmpty {
                        Button("Usar anônimo") {
                            if HuggingFaceAccess.save("") {
                                hfToken = ""; accountStatus = "Acesso anônimo selecionado"
                            } else { accountStatus = "Não foi possível remover o token." }
                        }.disabled(checkingAccount)
                    }
                }.font(.caption2)
                if let accountStatus {
                    Text(accountStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        Text("Na nuvem, os stems ficam salvos no iPhone quando prontos. " +
             "Se a GPU falhar, a CPU não iniciará uma segunda separação automaticamente.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    @MainActor
    private func refreshGPUStatus() async {
        isCheckingGPU = true
        gpuStatus = nil
        gpuStatusMessage = nil
        defer { isCheckingGPU = false }
        do {
            let status = try await CloudStemWorker.checkStatus()
            guard !Task.isCancelled, computeLocation == .huggingFace else { return }
            gpuStatus = status
            gpuStatusMessage = status.statusMessage
        } catch {
            guard !Task.isCancelled, computeLocation == .huggingFace else { return }
            gpuStatusMessage = error.localizedDescription
        }
    }

    private func listen(to url: URL) {
        audio.pause()
        previewURL = url
    }
}
