import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var audio = AudioEngineManager()

    @State private var speed: Float = 1.0
    @State private var reverb: Float = 0
    @State private var bass: Float = 0
    @State private var keepOriginalPitch = false
    @State private var isVertical = false

    @State private var showImporter = false
    @State private var exportFormat: ExportFormat = .m4a
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    // Download por link do YouTube (via microserviço)
    @StateObject private var downloader = DownloadManager()
    @State private var youtubeLink = ""
    @State private var coverURL: URL?
    @State private var relatedVideos: [RelatedVideo] = []
    @State private var isLoadingRelated = false
    @State private var relatedSourceURL: String?
    @State private var relatedRequestID = UUID()
    @State private var pendingDeepLink: String?
    @FocusState private var isLinkFieldFocused: Bool
    @State private var showServerSettings = false

    @AppStorage(TelemetryManager.enabledKey) private var telemetryEnabled = false
    @AppStorage("selectedTheme") private var currentTheme: AppTheme = .acid
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    // Troque pelo seu link (Ko-fi, GitHub Sponsors, página com QR Code do Pix…)
    private let donationURL = URL(string: "https://ko-fi.com/SEU_USUARIO")!

    private var hasTrack: Bool { audio.fileName != nil }
    private var trimmedLink: String { youtubeLink.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Tom resultante: 0 se "Manter o tom original", senão acompanha a velocidade (efeito vinil).
    private var computedPitch: Float {
        keepOriginalPitch ? 0 : 1200 * log2(speed)
    }

    var body: some View {
        ZStack {
            // Luz ambiente na cor do tema: troca com crossfade.
            AmbientBackground(theme: currentTheme)
                .id(currentTheme)
                .transition(.opacity)

            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    header
                    youtubeField
                    trackCard
                    relatedSection
                    presets
                    controls
                    exportSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(currentTheme.accent)
        .preferredColorScheme(.dark)
        .onOpenURL { incomingURL in
            guard let components = URLComponents(
                url: incomingURL,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "nightcore",
            components.host?.lowercased() == "download",
            components.user == nil,
            components.password == nil,
            components.port == nil else { return }

            guard let rawLink = components.queryItems?.first(where: { $0.name == "link" })?.value else {
                downloader.errorMessage = "Faltou parâmetro 'link' em: \(incomingURL.absoluteString)"
                return
            }

            guard let sourceURL = validatedYouTubeURL(rawLink) else {
                downloader.errorMessage = "O Swift rejeitou este link exato: \(rawLink)"
                return
            }

            downloader.errorMessage = nil
            youtubeLink = sourceURL.absoluteString

            if downloader.isDownloading {
                pendingDeepLink = youtubeLink
            } else {
                pendingDeepLink = nil
                startDownload()
            }
        }
        .task(id: relatedRequestID) { await loadRelatedVideos() }
        .onChange(of: downloader.isDownloading) { _, downloading in
            guard !downloading, let link = pendingDeepLink else { return }
            pendingDeepLink = nil
            youtubeLink = link
            startDownload()
        }
        // Áudio muda instantaneamente enquanto o dedo arrasta
        .onChange(of: speed) { _, value in
            audio.setSpeed(value)
            applyPitch()
        }
        .onChange(of: keepOriginalPitch) { _, _ in applyPitch() }
        .onChange(of: reverb) { _, value in audio.setReverb(value) }
        .onChange(of: bass)   { _, value in audio.setBass(value) }
        .onChange(of: telemetryEnabled) { _, enabled in
            if !enabled { TelemetryManager.shared.discardPending() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { TelemetryManager.shared.flush() }
            if phase == .active { downloader.warmUp() }   // acorda o Render ao voltar para o app
        }
        .onChange(of: isLinkFieldFocused) { _, focused in
            if focused { downloader.warmUp() }            // cold start enquanto o usuário cola o link
        }
        .task { downloader.warmUp() }
        .sheet(isPresented: $showServerSettings) {
            ServerSettingsView(downloader: downloader, accent: currentTheme.accent)
                .presentationDetents([.medium])
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Ops", isPresented: Binding(get: { errorMessage != nil },
                                           set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: DS.Spacing.s) {
            AppIconView(theme: currentTheme, showsBackground: false, isPlaying: audio.isPlaying)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("Nightcore Lab")
                    .font(DS.Typography.display)
                    .foregroundStyle(DS.Ink.primary)
                Text(currentTheme.displayName.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(2.5)
                    .foregroundStyle(currentTheme.accent)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            Spacer(minLength: 0)

            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    headerButton("heart.fill", label: "Apoiar o projeto") {
                        openURL(donationURL)
                    }

                    // Mostra o ícone do modo para o qual o botão vai trocar
                    headerButton(isVertical ? "slider.horizontal.3" : "slider.vertical.3",
                                 label: isVertical ? "Sliders horizontais" : "Sliders verticais (mesa de som)") {
                        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { isVertical.toggle() }
                    }
                    .sensoryFeedback(.impact(weight: .medium), trigger: isVertical)

                    themeButton
                    importButton
                }
            }
        }
    }

    private func headerButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(currentTheme.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .glassSurface(Circle(), theme: currentTheme, depth: 0.4)
        }
        .accessibilityLabel(label)
    }

    /// Cicla acid → crimson → cyber.
    private var themeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.45)) {
                currentTheme = currentTheme.next
            }
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(currentTheme.accent)
                .symbolEffect(.bounce, value: currentTheme)
                .frame(width: 40, height: 40)
                .glassSurface(Circle(), theme: currentTheme, isActive: true, pulses: false,
                              glowIntensity: 0.6, depth: 0.4)
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: currentTheme)
        .accessibilityLabel("Trocar tema")
        .accessibilityValue(currentTheme.displayName)
        .accessibilityHint("Alterna entre Acid, Crimson e Cyber")
    }

    /// Ação principal: pulsa enquanto não há música carregada, para guiar o primeiro uso.
    private var importButton: some View {
        Button {
            showImporter = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(currentTheme.onAccent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(currentTheme.accent))
                .background {
                    GlowPulse(shape: Circle(), color: currentTheme.accent,
                              isActive: !hasTrack && !downloader.isDownloading, blur: 10)
                }
        }
        .accessibilityLabel("Importar música")
    }

    // MARK: - Campo do link (vidro)

    /// [servidor] [link…] [colar | baixar | cancelar]
    private var youtubeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    showServerSettings = true
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(currentTheme.accent.opacity(0.75))
                        .frame(width: 28, height: 36)
                }
                .disabled(downloader.isDownloading)
                .accessibilityLabel("Configurar servidor")

                TextField("", text: $youtubeLink,
                          prompt: Text("Cole um link do YouTube").foregroundColor(DS.Ink.tertiary))
                    .font(DS.Typography.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .foregroundStyle(DS.Ink.primary)
                    .focused($isLinkFieldFocused)
                    .onSubmit(startDownload)
                    .disabled(downloader.isDownloading)
                    .opacity(downloader.isDownloading ? 0.5 : 1)

                linkAction
                    .frame(width: 36, height: 36)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassSurface(Capsule(), theme: currentTheme,
                          isActive: isLinkFieldFocused || downloader.isDownloading,
                          depth: 0.7)

            if downloader.isDownloading {
                Text(downloadStatusText)
                    .font(DS.Typography.captionNumeric)
                    .foregroundStyle(DS.Ink.secondary)
                    .padding(.leading, 16)
                    .contentTransition(.numericText())
            } else if let message = downloader.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Ink.error)
                    .padding(.leading, 16)
            }
            if pendingDeepLink != nil {
                Text("Link recebido. O próximo download começa ao terminar este.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(currentTheme.accent)
                    .padding(.leading, 16)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: downloader.isDownloading)
        .animation(.easeInOut(duration: 0.2), value: isLinkFieldFocused)
        .animation(.easeInOut(duration: 0.2), value: trimmedLink.isEmpty)
    }

    @ViewBuilder
    private var linkAction: some View {
        if downloader.isDownloading {
            // Toque no indicador para cancelar
            Button {
                downloader.cancel()
            } label: {
                ZStack {
                    ProgressView()
                        .tint(currentTheme.accent)
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(currentTheme.accent.opacity(0.85))
                }
            }
            .accessibilityLabel("Cancelar download")
        } else if trimmedLink.isEmpty {
            // Botão de colar do sistema: não dispara o aviso de privacidade da área de transferência
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in pasteAndDownload(text) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(currentTheme.accent)
            .foregroundStyle(currentTheme.onAccent)
        } else {
            // Link pronto: o botão pulsa chamando para o download
            Button(action: startDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(currentTheme.accent)
                    .background {
                        GlowPulse(shape: Circle(), color: currentTheme.accent, isActive: true, blur: 8)
                    }
            }
            .accessibilityLabel("Baixar áudio do link")
        }
    }

    private var downloadStatusText: String {
        if downloader.downloadProgress > 0 {
            return "Baixando… \(Int(downloader.downloadProgress * 100))%"
        }
        return downloader.isRetrying
            ? "Servidor acordando, tentando de novo…"
            : "Extraindo o áudio no servidor…"
    }

    // MARK: - Cartão da música (vidro)

    private var trackCard: some View {
        HStack(spacing: DS.Spacing.m) {
            Button {
                audio.togglePlayback()
            } label: {
                VinylPlaybackArtwork(coverURL: coverURL,
                                     isPlaying: audio.isPlaying,
                                     theme: currentTheme)
                    .id(coverURL)
            }
            .disabled(!hasTrack)
            .opacity(hasTrack ? 1 : 0.4)
            .accessibilityLabel(audio.isPlaying ? "Pausar" : "Tocar")

            VStack(alignment: .leading, spacing: 4) {
                Text(audio.fileName ?? "Nenhuma música")
                    .font(DS.Typography.trackTitle)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                Text(hasTrack ? durationText : "Toque em + ou cole um link")
                    .font(DS.Typography.subtitleNumeric)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            LevelBars(color: currentTheme.accent, isAnimating: audio.isPlaying)
                .opacity(hasTrack ? 1 : 0)
        }
        .padding(DS.Spacing.m)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous),
                      theme: currentTheme, isActive: audio.isPlaying)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .onTapGesture { if !hasTrack { showImporter = true } }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if relatedSourceURL != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PRÓXIMAS FAIXAS")
                        .font(.caption.weight(.heavy))
                        .tracking(2)
                        .foregroundStyle(currentTheme.accent)
                    Spacer()
                    if isLoadingRelated {
                        ProgressView().tint(currentTheme.accent)
                            .accessibilityLabel("Carregando sugestões")
                    } else {
                        Button {
                            relatedRequestID = UUID()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Atualizar sugestões")
                    }
                }

                if !relatedVideos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(relatedVideos) { video in
                                RelatedVideoCard(video: video, theme: currentTheme,
                                                 isEnabled: !downloader.isDownloading) {
                                    guard !downloader.isDownloading else { return }
                                    youtubeLink = video.url.absoluteString
                                    startDownload()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else if isLoadingRelated {
                    Text("Buscando músicas para continuar…")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Ink.secondary)
                } else {
                    Text(downloader.relatedErrorMessage ?? "Nenhuma sugestão disponível para esta faixa.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Ink.secondary)
                }
            }
        }
    }

    private var durationText: String {
        let seconds = Int(audio.duration / Double(speed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Presets

    private var presets: some View {
        GlassGroup(spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                presetButton("Redefinir", speed: 1.0, reverb: 0, bass: 0)
                presetButton("Lentidão", speed: 0.8, reverb: 35, bass: 0)
                presetButton("Nightcore", speed: 1.25, reverb: 0, bass: 5)
            }
        }
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
    }

    private func presetButton(_ title: String, speed s: Float, reverb r: Float, bass b: Float) -> some View {
        let isSelected = hasTrack
            && abs(speed - s) < 0.001 && abs(reverb - r) < 0.01 && abs(bass - b) < 0.01

        return Button {
            withAnimation(.spring(duration: 0.35)) {
                speed = s
                reverb = r
                bass = b
            }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? currentTheme.accent : DS.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .glassSurface(Capsule(), theme: currentTheme, isActive: isSelected, pulses: false,
                              glowIntensity: 0.5, depth: 0.4)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Controles

    private var controls: some View {
        VStack(spacing: DS.Spacing.l) {
            pitchToggle
            sliders
        }
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
    }

    private var pitchToggle: some View {
        Toggle(isOn: $keepOriginalPitch) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Manter o tom original")
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.Ink.primary)
                Text(keepOriginalPitch
                     ? "Só a velocidade muda"
                     : "Tom acompanha a velocidade: \(String(format: "%+.0f", computedPitch)) cents")
                    .font(DS.Typography.captionNumeric)
                    .foregroundStyle(DS.Ink.secondary)
                    .contentTransition(.numericText())
            }
        }
        .tint(currentTheme.accent)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, 12)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous),
                      theme: currentTheme, depth: 0.6)
        .sensoryFeedback(.impact(weight: .light), trigger: keepOriginalPitch)
    }

    /// Mesmo conjunto de sliders nos dois modos. O AnyLayout troca só o arranjo,
    /// preservando a identidade das views, então a rotação é animada em vez de recriada.
    private var sliders: some View {
        let layout = isVertical
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 14))
            : AnyLayout(VStackLayout(spacing: DS.Spacing.l))

        return layout {
            GiantSlider(title: "Velocidade", value: $speed,
                        range: AudioEngineManager.speedRange, defaultValue: 1.0,
                        theme: currentTheme, isVertical: isVertical) { String(format: "%.2f×", $0) }

            GiantSlider(title: "Reverb", value: $reverb,
                        range: AudioEngineManager.reverbRange, defaultValue: 0,
                        theme: currentTheme, isVertical: isVertical) { String(format: "%.0f%%", $0) }

            GiantSlider(title: "Baixo", value: $bass,
                        range: AudioEngineManager.bassRange, defaultValue: 0,
                        theme: currentTheme, isVertical: isVertical) { String(format: "+%.1f dB", $0) }
        }
    }

    // MARK: - Exportar

    private var exportSection: some View {
        VStack(spacing: 14) {
            HStack {
                SectionLabel(text: "Exportar")
                Spacer()
            }

            Picker("Formato", selection: $exportFormat) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)

            Button(action: export) {
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        // Escurece a parte já renderizada
                        Capsule()
                            .fill(.black.opacity(0.18))
                            .frame(width: geo.size.width * audio.exportProgress)
                    }
                    Text(audio.isExporting
                         ? "Renderizando… \(Int(audio.exportProgress * 100))%"
                         : "Exportar e compartilhar")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(currentTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                }
                .frame(height: 56)
                .background(Capsule().fill(currentTheme.accent))
                .clipShape(Capsule())
                .background {
                    GlowPulse(shape: Capsule(), color: currentTheme.accent, isActive: audio.isExporting)
                }
            }
            .disabled(!hasTrack || audio.isExporting)
            .opacity(hasTrack ? 1 : 0.35)

            Toggle(isOn: $telemetryEnabled) {
                Text("Enviar estatísticas anônimas de uso")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Ink.secondary)
            }
            .tint(.gray)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    // MARK: - Ações

    private func applyPitch() {
        audio.setPitch(computedPitch)
    }

    /// Ponte rede → DSP: baixa o .m4a e injeta no mesmo motor de áudio que a tela usa.
    private func startDownload() {
        guard !downloader.isDownloading else { return }
        let sourceURL = trimmedLink
        guard DownloadManager.looksLikeYouTube(sourceURL) else {
            downloader.errorMessage = "Cole o link de um vídeo do YouTube."
            return
        }
        isLinkFieldFocused = false
        resetRelatedVideos()
        downloader.downloadAudio(youtubeURL: sourceURL) { localURL, downloadedCoverURL in
            do {
                try audio.load(url: localURL)
                coverURL = downloadedCoverURL
                applyPitch()
                youtubeLink = ""
                relatedSourceURL = sourceURL
                relatedRequestID = UUID()
            } catch {
                errorMessage = "Não foi possível abrir o áudio baixado: \(error.localizedDescription)"
            }
        }
    }

    private func validatedYouTubeURL(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Decodifica se vier codificado em percentagem
        if let decoded = value.removingPercentEncoding {
            value = decoded
        }

        // Garante protocolo
        if !value.contains("://") {
            value = "https://" + value
        }

        // Extrai o Video ID de forma infalível por Regex, ignorando parâmetros malucos
        // Isto apanha qualquer link do YouTube (shorts, youtu.be, watch?v=, etc.)
        let pattern = "(?:v=|/|shorts/|embed/)([A-Za-z0-9_-]{11})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }

        let videoID = String(value[range])

        // Reconstrói sempre um link limpo e canónico do YouTube para o motor baixar
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "www.youtube.com"
        canonical.path = "/watch"
        canonical.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return canonical.url
    }

    private func resetRelatedVideos() {
        relatedSourceURL = nil
        relatedVideos = []
        isLoadingRelated = false
        relatedRequestID = UUID() // Cancela a consulta anterior vinculada à view.
    }

    @MainActor
    private func loadRelatedVideos() async {
        guard let sourceURL = relatedSourceURL else { return }
        let requestID = relatedRequestID
        isLoadingRelated = true
        let videos = await downloader.fetchRelatedVideos(for: sourceURL)
        guard !Task.isCancelled, requestID == relatedRequestID,
              sourceURL == relatedSourceURL else { return }
        relatedVideos = videos
        isLoadingRelated = false
    }

    /// Colar com um toque: se o texto for um link do YouTube, já inicia o download.
    private func pasteAndDownload(_ text: String) {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        youtubeLink = link
        if DownloadManager.looksLikeYouTube(link) {
            startDownload()
        } else {
            downloader.errorMessage = "O texto colado não é um link do YouTube."
        }
    }

    private func importFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            // Copia para o sandbox para não depender do acesso de segurança depois.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            try audio.load(url: destination)
            coverURL = nil
            resetRelatedVideos()
            applyPitch()
        } catch {
            TelemetryManager.shared.log(.importFailed)
            errorMessage = "Não foi possível abrir o arquivo: \(error.localizedDescription)"
        }
    }

    private func export() {
        let format = exportFormat
        Task {
            let start = ContinuousClock.now
            do {
                let url = try await audio.exportAudio(format: format)
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                TelemetryManager.shared.log(.exportCompleted(format: format, renderSeconds: seconds))
                shareItem = ShareItem(url: url)
            } catch {
                TelemetryManager.shared.log(.exportFailed(format: format))
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Cartão de sugestão

private struct RelatedVideoCard: View {
    let video: RelatedVideo
    let theme: AppTheme
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                AsyncImage(url: video.thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    theme.accent.opacity(0.12)
                }
                .frame(width: 152, height: 120)
                .opacity(0.55)

                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .symbolEffect(.pulse, options: .repeating,
                                          isActive: isEnabled && !reduceMotion)
                            .shadow(color: theme.accent.opacity(0.65), radius: 8)
                    }
                    Spacer(minLength: 0)
                    Text(video.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .frame(width: 152, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel("Baixar \(video.title)")
    }
}

// MARK: - Capa de vinil

private struct VinylPlaybackArtwork: View {
    let coverURL: URL?
    let isPlaying: Bool
    let theme: AppTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinDegrees: Double = 0
    @State private var spinStartedAt: Date?

    private var shouldSpin: Bool {
        isPlaying && coverURL != nil && !reduceMotion
    }

    var body: some View {
        TimelineView(.animation(paused: !shouldSpin)) { context in
            AsyncImage(url: coverURL) { phase in
                ZStack {
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                            .overlay(Circle().fill(.black).frame(width: 12, height: 12))
                            .rotationEffect(.degrees(angle(at: context.date)))
                    } else {
                        // Sem capa, carregando ou com falha: mantém o botão utilizável.
                        Circle().fill(theme.accent)
                    }

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(phase.image != nil ? Color.white.opacity(0.8) : theme.onAccent)
                        .shadow(color: .black.opacity(phase.image != nil ? 0.7 : 0),
                                radius: 4)
                }
                .frame(width: 64, height: 64)
            }
        }
        .shadow(color: theme.accent.opacity(isPlaying ? 0.5 : 0.2), radius: 14)
        .accessibilityHidden(true) // O botão pai fornece o rótulo Tocar/Pausar.
        .onAppear {
            if shouldSpin { spinStartedAt = Date() }
        }
        .onChange(of: shouldSpin) { _, spinning in
            let now = Date()
            spinDegrees = angle(at: now).truncatingRemainder(dividingBy: 360)
            spinStartedAt = spinning ? now : nil
        }
        .onDisappear {
            spinDegrees = angle(at: Date()).truncatingRemainder(dividingBy: 360)
            spinStartedAt = nil
        }
    }

    private func angle(at date: Date) -> Double {
        guard let spinStartedAt else { return spinDegrees }
        // Uma volta a cada 3 segundos; a pausa conserva o ângulo atual.
        return spinDegrees + max(0, date.timeIntervalSince(spinStartedAt)) * 120
    }
}

// MARK: - Slider gigante (fader)

struct GiantSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    /// Tema ativo: a barra usa o gradiente acento → secundária do tema.
    let theme: AppTheme
    /// true = fader de mesa de som: a barra cresce de baixo para cima.
    var isVertical: Bool = false
    let format: (Float) -> String

    @State private var isDragging = false

    private let thickness: CGFloat = 72        // altura (horizontal) ou largura máxima (vertical)
    private let verticalLength: CGFloat = 320  // altura do fader vertical

    private var span: Float { range.upperBound - range.lowerBound }
    private var progress: CGFloat { CGFloat((value - range.lowerBound) / span) }
    private var defaultPosition: CGFloat { CGFloat((defaultValue - range.lowerBound) / span) }
    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.track, style: .continuous)
    }

    var body: some View {
        Group {
            if isVertical {
                VStack(spacing: DS.Spacing.s) {
                    SectionLabel(text: title)
                    valueLabel
                    track
                        .frame(maxWidth: thickness)
                        .frame(height: verticalLength)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    HStack {
                        SectionLabel(text: title)
                        Spacer()
                        valueLabel
                    }
                    track
                        .frame(height: thickness)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }

    private var valueLabel: some View {
        Text(format(value))
            .font(isVertical ? DS.Typography.valueCompact : DS.Typography.value)
            .foregroundStyle(isDragging ? theme.accent : DS.Ink.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    // MARK: Trilho

    private var track: some View {
        GeometryReader { geo in
            let length = isVertical ? geo.size.height : geo.size.width

            ZStack(alignment: isVertical ? .bottom : .leading) {
                // Sulco rebaixado: borda escura em cima e clara embaixo, como um fader físico
                trackShape
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        trackShape.strokeBorder(
                            LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.09)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                    )

                // Preenchimento: cresce da esquerda (horizontal) ou de baixo (vertical)
                trackShape
                    .fill(theme.gradient(vertical: isVertical))
                    .frame(width: isVertical ? nil : length * progress,
                           height: isVertical ? length * progress : nil)
                    .shadow(color: theme.accent.opacity(isDragging ? 0.7 : 0.35),
                            radius: isDragging ? 16 : 9)
                    .overlay(alignment: isVertical ? .top : .trailing) {
                        // Linha de leitura na ponta da barra
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: isVertical ? 28 : 3, height: isVertical ? 3 : 28)
                            .padding(isVertical ? .top : .trailing, 10)
                            .opacity(progress > 0.08 ? 1 : 0)
                    }

                // Marcador do valor neutro
                if defaultPosition > 0 && defaultPosition < 1 {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: isVertical ? 28 : 2, height: isVertical ? 2 : 28)
                        .offset(x: isVertical ? 0 : length * defaultPosition - 1,
                                y: isVertical ? -(length * defaultPosition - 1) : 0)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        // Vertical: y cresce para baixo na tela, então invertemos (topo = máximo).
                        let raw = isVertical
                            ? 1 - gesture.location.y / length
                            : gesture.location.x / length
                        let fraction = min(max(raw, 0), 1)
                        var newValue = range.lowerBound + Float(fraction) * span
                        // "Imã" no valor neutro (±2%)
                        if abs(newValue - defaultValue) < span * 0.02 { newValue = defaultValue }
                        value = newValue
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .scaleEffect(isDragging ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: isDragging)
        .sensoryFeedback(.selection, trigger: value == defaultValue)
    }
}

// MARK: - Share sheet

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}

