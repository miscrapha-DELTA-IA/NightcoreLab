import SwiftUI
import UniformTypeIdentifiers
import SDWebImageSwiftUI

struct ContentView: View {
    @State private var audio = AudioEngineManager()

    @State private var speed: Float = 1.0
    @State private var reverb: Float = 0
    @State private var bass: Float = 0
    @State private var keepOriginalPitch = false
    @State private var isVertical = false
    @State private var isAdjustingSlider = false

    /// Estilo do fundo do mini-player (botão de vinil): fosco → nítido → em movimento.
    @State private var bgStyle: PlayerBackgroundStyle = .blurred

    @State private var showImporter = false
    @State private var exportFormat: ExportFormat = .m4a
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    // Download por link do YouTube (via microserviço)
    @StateObject private var downloader = AudioDownloadManager.shared
    @State private var youtubeLink = ""
    @State private var coverURL: URL?
    @State private var relatedVideos: [Track] = []
    @State private var playingTrackID: String?
    @State private var isLoadingRelated = false
    @State private var relatedSourceURL: String?
    @State private var relatedRequestID = UUID()
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
                        .disabled(audio.isExporting)
                    SearchView(downloader: downloader, theme: currentTheme,
                               isEnabled: !audio.isExporting) { track, upcoming in
                        playTrack(track, upcoming: upcoming)
                    }
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
            .scrollDisabled(isAdjustingSlider)
.onPreferenceChange(SliderAdjustingKey.self) { isAdjustingSlider = $0 }
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

            var receivedLink = (components.queryItems?.first(where: { $0.name == "link" })?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !receivedLink.contains("://"), let decoded = receivedLink.removingPercentEncoding {
                receivedLink = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !receivedLink.isEmpty else {
                downloader.errorMessage = "O Atalho abriu o app, mas enviou o link vazio. Verifique a URL compartilhada no Atalho ou cole o link nesta caixa."
                isLinkFieldFocused = !downloader.isDownloading && !audio.isExporting
                return
            }

            downloader.errorMessage = nil
            youtubeLink = receivedLink
            isLinkFieldFocused = !downloader.isDownloading && !audio.isExporting
        }
        .task(id: relatedRequestID) { await loadRelatedVideos() }
        .onChange(of: audio.isPlaying) { _, playing in
            if playing { prefetchUpcoming() }
        }
        // Áudio muda instantaneamente enquanto o dedo arrasta
        .onChange(of: speed) { _, _ in
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
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
        .disabled(audio.isExporting || downloader.isDownloading)
        .accessibilityLabel("Importar música MP3, M4A, WAV ou AIFF")
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

    /// Forma única do card: recorte do fundo, vidro e área de toque usam a mesma, para a
    /// imagem nunca vazar dos cantos arredondados.
    private var trackCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
    }

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
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(hasTrack ? durationText : "Toque em + ou cole um link")
                    .font(DS.Typography.subtitleNumeric)
                    .foregroundStyle(hasTrack ? Color.white : DS.Ink.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            LevelBars(color: currentTheme.accent, isAnimating: audio.isPlaying)
                .opacity(hasTrack ? 1 : 0)

            bgStyleButton
        }
        .padding(DS.Spacing.m)
        // Fundo da capa: usa `.background` para ter exatamente o tamanho do card.
        // Uma imagem `scaledToFill` ou um `GeometryReader` como irmão no ZStack esticariam a altura.
        .background {
            if let url = coverURL {
                PlayerBackgroundView(style: bgStyle, imageURL: url)
                    .id(url)
            }
        }
        .clipShape(trackCardShape)
        .glassSurface(trackCardShape, theme: currentTheme, isActive: audio.isPlaying)
        .contentShape(trackCardShape)
        .onTapGesture { if !hasTrack { showImporter = true } }
    }

    /// Botão vinil: avança o fundo do player em ciclo fosco → nítido → em movimento.
    /// Sem capa não há o que estilizar, então fica desativado.
    private var bgStyleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                bgStyle = bgStyle.next
            }
        } label: {
            Image(systemName: "opticaldisc")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(currentTheme.accent)
                .symbolEffect(.bounce, value: bgStyle)
                .frame(width: 36, height: 36)
                .glassSurface(Circle(), theme: currentTheme, depth: 0.4)
        }
        .disabled(coverURL == nil)
        .opacity(coverURL == nil ? 0.4 : 1)
        .sensoryFeedback(.selection, trigger: bgStyle)
        .accessibilityLabel("Estilo do fundo do player")
        .accessibilityValue(bgStyle.displayName)
        .accessibilityHint("Alterna entre fosco, nítido e em movimento")
    }

    private var relatedSection: some View {
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
                } else if relatedSourceURL != nil {
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
                            RelatedVideoCard(video: downloader.cachedTrack(video), theme: currentTheme,
                                             isEnabled: !audio.isExporting) {
                                let index = relatedVideos.firstIndex(where: { $0.id == video.id }) ?? 0
                                playTrack(video, upcoming: Array(relatedVideos.dropFirst(index + 1)))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if relatedSourceURL == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                                .overlay(Image(systemName: "music.note")
                                    .foregroundStyle(currentTheme.accent.opacity(0.4)))
                                .frame(width: 152, height: 120)
                                .accessibilityHidden(true)
                        }
                    }
                }
                Text("Baixe uma música do YouTube para carregar as próximas faixas.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Ink.secondary)
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
            .disabled(audio.isExporting)

            Text(exportFormat.qualityDescription)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Ink.secondary)

            Text("Entrada: MP3, M4A, WAV e AIFF")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Ink.tertiary)

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
            .disabled(!hasTrack || audio.isExporting || downloader.isDownloading)
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
        audio.setPlayback(speed: speed, keepOriginalPitch: keepOriginalPitch)
    }

    /// Ponte rede → DSP: baixa o .m4a e injeta no mesmo motor de áudio que a tela usa.
    private func startDownload() {
        guard !audio.isExporting else { return }
        guard let track = Track.from(url: trimmedLink) else {
            downloader.errorMessage = "Cole o link de um vídeo do YouTube."
            return
        }
        playTrack(track, upcoming: [])
    }

    private func playTrack(_ track: Track, upcoming: [Track]) {
        guard !audio.isExporting else { return }
        isLinkFieldFocused = false
        resetRelatedVideos()
        relatedVideos = upcoming
        downloader.select(track) { localURL, downloadedCoverURL in
            do {
                try audio.load(url: localURL)
                coverURL = downloadedCoverURL
                applyPitch()
                youtubeLink = ""
                playingTrackID = track.id
                audio.play()
                if upcoming.isEmpty {
                    relatedSourceURL = track.url.absoluteString
                    relatedRequestID = UUID()
                }
                prefetchUpcoming()
            } catch {
                errorMessage = "Não foi possível abrir o áudio baixado: \(error.localizedDescription)"
            }
        }
    }

    private func prefetchUpcoming() {
        guard audio.isPlaying, let playingTrackID else { return }
        downloader.prefetch(relatedVideos, playing: playingTrackID)
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
        prefetchUpcoming()
    }

    /// Colar com um toque: se o texto for um link do YouTube, já inicia o download.
    private func pasteAndDownload(_ text: String) {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        youtubeLink = link
        if AudioDownloadManager.looksLikeYouTube(link) {
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
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("nightcore_import_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var imported = false
            defer { if !imported { try? FileManager.default.removeItem(at: folder) } }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            try audio.load(url: destination)
            imported = true
            coverURL = nil
            playingTrackID = nil
            downloader.cancel()
            resetRelatedVideos()
            applyPitch()
        } catch {
            TelemetryManager.shared.log(.importFailed)
            errorMessage = "Não foi possível abrir o arquivo: \(error.localizedDescription)"
        }
    }

    private func export() {
        guard !downloader.isDownloading, !audio.isExporting else { return }
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
    let video: Track
    let theme: AppTheme
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                WebImage(url: video.thumbnailURL)
                    .resizable()
                    .transition(.fade(duration: 0.2))
                    .scaledToFill()
                .frame(width: 152, height: 120)
                .opacity(0.55)

                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Image(systemName: video.isCached ? "checkmark.circle.fill" : "arrow.down.circle.fill")
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
        .accessibilityLabel("\(video.isCached ? "Tocar" : "Baixar e tocar") \(video.title)")
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

/// Sobe do slider até a página: true enquanto algum slider está sendo ajustado.
struct SliderAdjustingKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

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
    /// Zera sozinho quando o toque termina OU é cancelado (ex.: a página assumiu a rolagem).
    @GestureState private var isTouching = false
    /// Valor "cru" durante o arrasto; o ímã do valor neutro só afeta o valor exibido.
    @State private var raw: Float = 0
    @State private var lastAlong: CGFloat = 0
    @State private var lock: AxisLock = .undecided
    /// 1 = arrasto normal; menor = ajuste mais fino (dedo mais longe da barra).
    @State private var precision: Float = 1

    private enum AxisLock { case undecided, adjust, scroll }

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
        .preference(key: SliderAdjustingKey.self, value: isDragging)
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
        HStack(spacing: 6) {
            if isDragging, let precisionLabel {
                Text(precisionLabel)
                    .font(DS.Typography.captionNumeric)
                    .foregroundStyle(theme.accent)
            }
            Text(format(value))
                .font(isVertical ? DS.Typography.valueCompact : DS.Typography.value)
                .foregroundStyle(isDragging ? theme.accent : DS.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    private var precisionLabel: String? {
        switch precision {
        case ..<0.15: return "⅒×"
        case ..<0.3:  return "¼×"
        case ..<0.9:  return "½×"
        default:      return nil
        }
    }

    // MARK: Gesto

    /// Horizontal: arrasto direto, mas só vira ajuste se o movimento for claramente horizontal;
    /// gesto vertical é rolagem da página e não toca no slider.
    private func adjustHorizontal(_ g: DragGesture.Value, length: CGFloat) {
        if lock == .undecided {
            lock = abs(g.translation.width) > abs(g.translation.height) * 1.3 ? .adjust : .scroll
            if lock == .adjust { beginAdjust() }
        }
        guard lock == .adjust else { return }
        applyDrag(along: g.translation.width, across: g.translation.height, length: length, sign: 1)
    }

    /// Vertical (mesa de som): arrasto na vertical conflita com a rolagem, então o fader
    /// só é "agarrado" após segurar ~0,15 s. Um deslize rápido continua rolando a página.
    private func adjustVertical(_ g: DragGesture.Value?, length: CGFloat) {
        if lock == .undecided {
            lock = .adjust
            beginAdjust()
        }
        guard let g else { return }
        applyDrag(along: g.translation.height, across: g.translation.width, length: length, sign: -1)
    }

    private func beginAdjust() {
        raw = value
        lastAlong = 0
        isDragging = true
    }

    private func endAdjust() {
        lock = .undecided
        precision = 1
        isDragging = false
    }

    /// Ajuste relativo: o valor parte de onde está e só muda pelo quanto o dedo se mexeu.
    /// Afastar o dedo da barra (no eixo transversal) reduz a razão: ½×, ¼×, ⅒×.
    private func applyDrag(along: CGFloat, across: CGFloat, length: CGFloat, sign: Float) {
        guard length > 0 else { return }
        let delta = Float((along - lastAlong) / length)
        lastAlong = along

        let ratio = precisionRatio(forDistance: abs(across))
        if ratio != precision { precision = ratio }

        raw = min(max(raw + sign * delta * span * ratio, range.lowerBound), range.upperBound)
        // Ímã no valor neutro, sem prender: `raw` continua acumulando por baixo.
        value = abs(raw - defaultValue) < span * 0.02 * ratio ? defaultValue : raw
    }

    private func precisionRatio(forDistance distance: CGFloat) -> Float {
        switch distance {
        case ..<48:  return 1
        case ..<110: return 0.5
        case ..<190: return 0.25
        default:     return 0.1
        }
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
            // `simultaneousGesture`: a página continua rolando até o gesto provar que é um ajuste.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .updating($isTouching) { _, state, _ in state = true }
                    .onChanged { g in
                        guard !isVertical else { return }
                        adjustHorizontal(g, length: length)
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.15, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($isTouching) { _, state, _ in state = true }
                    .onChanged { phase in
                        guard isVertical, case .second(true, let g) = phase else { return }
                        adjustVertical(g, length: length)
                    }
            )
            .onChange(of: isTouching) { _, touching in
                if !touching { endAdjust() }
            }
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
