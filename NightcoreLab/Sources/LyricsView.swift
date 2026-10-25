import SwiftUI
import Foundation
import SDWebImageSwiftUI

struct LyricLine: Identifiable, Equatable {
    let time: TimeInterval
    let text: String
    var id: TimeInterval { time }
}

enum LRCParser {
    static func parse(_ source: String) -> [LyricLine] {
        // Supports [mm:ss.xx], [mm:ss.xxx], multiple timestamps per line,
        // and ignores common LRC metadata tags.
        let pattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var lines: [LyricLine] = []
        for row in source.components(separatedBy: .newlines) {
            let range = NSRange(row.startIndex..<row.endIndex, in: row)
            let matches = regex.matches(in: row, range: range)
            guard !matches.isEmpty else { continue }
            let lyric = regex.stringByReplacingMatches(in: row, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for match in matches {
                func value(_ index: Int) -> String {
                    guard let range = Range(match.range(at: index), in: row) else { return "" }
                    return String(row[range])
                }
                guard let minutes = Double(value(1)), let seconds = Double(value(2)),
                      seconds < 60 else { continue }
                let fraction = value(3)
                let subsecond = fraction.isEmpty ? 0 :
                    (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
                lines.append(LyricLine(time: minutes * 60 + seconds + subsecond, text: lyric))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

/// The moving mask is isolated from the scrolling list. Only the active row
/// reads the audio clock at display cadence.
/// Persistent user preference; unlike the theme itself it belongs to Karaoke only.
enum LyricsColorMode: String, CaseIterable {
    case artwork
    case theme
}

private struct LyricsBackdrop: View {
    let track: Track

    var body: some View {
        GeometryReader { geometry in
            // Prefer the high-resolution artwork, falling back to the track thumbnail.
            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(track.id)/maxresdefault.jpg")) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else if case .failure = phase {
                    AsyncImage(url: track.thumbnailURL) { fallback in
                        if let image = fallback.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.black
                        }
                    }
                } else {
                    Color.black
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            // Keep the artwork sharp: darken instead of blurring it.
            .overlay {
                LinearGradient(
                    colors: [
                        .black.opacity(0.30),
                        .black.opacity(0.47),
                        .black.opacity(0.39)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LyricsView: View {
    let track: Track
    let audio: AudioEngineManager
    @Binding var theme: AppTheme
    @Binding var backgroundStyle: BackgroundStyle
    @Binding var lyricsCleanMode: Bool
    let dismiss: () -> Void
    var inline = false
    var prefetcher: LyricsPrefetcher?
    var onShowResult: (() -> Void)?

    @Environment(LyricsStore.self) private var lyricStore
    @State private var record: LyricsRecord?
    @State private var candidates: [LyricsRecord] = []
    @State private var manualCandidates: [LyricsRecord] = []
    @State private var manualHasSearched = false
    @State private var isChoosingLyrics = false
    @State private var showLyricsControlCenter = false
    @State private var queuedManualPicker = false
    @State private var manualQuery = ""
    @State private var manualSearchID = UUID()
    @State private var manualSearching = false
    @State private var transcribingAudio = false
    @State private var transcriptionMessage: String?
    @State private var pickerError: String?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var artworkTint: ArtworkTint?
    @AppStorage("lyricsColorMode") private var colorMode: LyricsColorMode = .artwork

    private var lyricAccent: Color {
        // A escolha do Control Center também afeta as letras no karaokê inline.
        switch colorMode {
        // If the artwork is grayscale/unavailable, use readable neutral white,
        // never the theme color; otherwise the two choices looked identical.
        case .artwork: return artworkTint?.color ?? .white
        case .theme: return theme.accent
        }
    }

    private func apply(_ selected: LyricsRecord, pin: Bool = false) {
        guard lyricStore.trackID == track.id else { return }
        record = selected
        if let synced = selected.syncedLyrics, !synced.isEmpty {
            lyricStore.load(trackID: track.id, rawLRC: synced,
                            needsReview: false, force: true)
        } else if let url = audio.visualAnalysisURL {
            lyricStore.loadFallback(trackID: track.id,
                                    plainText: selected.plainLyrics,
                                    sourceURL: url, duration: audio.duration,
                                    force: pin)
        }
        if pin, let prefetcher {
            let choice = LRCLIBRecord(legacy: selected)
            Task { await prefetcher.pin(choice, for: track.id) }
        }
        errorMessage = nil
    }

    private func generateAudioLyrics() {
        guard !transcribingAudio else { return }
        transcribingAudio = true
        transcriptionMessage = nil
        Task {
            let outcome = await lyricStore.transcribeCurrentAudio(
                sourceURL: audio.visualAnalysisURL, duration: audio.duration)
            transcriptionMessage = outcome.message
            transcribingAudio = false
        }
    }

    private func colorModeButton(_ mode: LyricsColorMode) -> some View {
        let selected = colorMode == mode
        let label = mode == .artwork ? "Capa" : "Tema"
        let icon = mode == .artwork ? "photo.fill" : "paintpalette.fill"
        return Button {
            withAnimation(.easeInOut(duration: 0.42)) {
                colorMode = mode
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(mode == .artwork ? (artworkTint?.color ?? .white) : theme.accent)
                    .frame(width: 8, height: 8)
                Image(systemName: icon)
                Text(label)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.68))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(selected ? lyricAccent.opacity(0.23) : .black.opacity(0.28))
            }
            .overlay {
                Capsule().strokeBorder(
                    selected ? lyricAccent.opacity(0.92) : .white.opacity(0.15),
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .artwork ? "Usar cor da capa" :
                            "Usar cor do tema \(theme.displayName)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var synchronizedLyrics: some View {
        KaraokeLyricsView(clock: audio.lyricsClock,
                          theme: .forAppTheme(theme),
                          accent: lyricAccent,
                          onShowResult: onShowResult,
                          sourceURL: audio.visualAnalysisURL)
            .mask {
                if inline { LyricsFadeMask() }
                else { Rectangle() }
            }
    }

    var body: some View {
        ZStack {
            if !inline {
                Color.black.ignoresSafeArea()
                LyricsBackdrop(track: track)
            }

            VStack(spacing: inline ? 10 : 18) {
                // Scoring chrome remains visible even while timed lyrics load or
                // when the catalog cannot provide a synchronized line list.
                if inline && lyricStore.lines.isEmpty {
                    KaraokeScoreHUD(session: lyricStore.scoring, accent: lyricAccent,
                                    onResult: onShowResult)
                }
                if inline {
                    HStack {
                        KaraokeScoringControls(store: lyricStore, audio: audio,
                            clock: audio.lyricsClock, accent: lyricAccent)
                        Spacer(minLength: 0)
                        Button {
                            showLyricsControlCenter = true
                        } label: {
                            Label("Legenda", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Configurações da legenda")
                        .accessibilityHint("Abre os ajustes de aparência, sincronização e escolha da letra")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                if !inline {
                HStack(spacing: 12) {
                    if let cover = track.thumbnailURL {
                        WebImage(url: cover)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 50, height: 50)
                            .background(GnarlyArtworkPlaceholder())
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        GnarlyArtworkPlaceholder()
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Fechar letras")
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
                }

                if !inline {
                HStack(spacing: 10) {
                    Text("COR DAS LETRAS")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.73))
                    Text("Aa")
                        .font(.caption.weight(.black))
                        .foregroundStyle(lyricAccent)
                        .animation(.easeInOut(duration: 0.28), value: lyricAccent)
                        .accessibilityLabel("Prévia da cor das letras")
                    Spacer(minLength: 4)
                    colorModeButton(.artwork)
                    colorModeButton(.theme)
                }
                .padding(.horizontal, 22)
                }

                if !inline, let record {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lyricStore.needsReview ? "CONFERIR LETRA" : "LETRA ENCONTRADA")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.65))
                            Text("\(record.artistName) — \(record.trackName)")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.white)
                        }
                        Spacer(minLength: 8)
                        Button("Trocar") { isChoosingLyrics = true }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(lyricAccent)
                    }
                    .padding(.horizontal, 22)
                } else if !inline && !loading {
                    HStack {
                        Text("Sem correspondência confirmada")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Button("Buscar letra") { isChoosingLyrics = true }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(lyricAccent)
                    }
                    .padding(.horizontal, 22)
                }

                if lyricStore.lines.contains(where: {
                    $0.provenance == .rhythmicCue
                }) && !lyricStore.lines.contains(where: {
                    $0.provenance == .autoTranscribed
                }) {
                    HStack(spacing: 8) {
                        Text("Guia rítmico disponível · sem palavras confirmadas")
                            .font(.caption2).foregroundStyle(.white.opacity(0.72))
                        Spacer(minLength: 6)
                        Button("Gerar letra", action: generateAudioLyrics)
                            .font(.caption.weight(.bold))
                            .disabled(transcribingAudio)
                            .accessibilityIdentifier("lyrics.generateFromRhythmicGuide")
                    }
                    .padding(.horizontal, 22)
                } else if lyricStore.lines.contains(where: {
                    $0.provenance == .autoTranscribed
                }) {
                    Text("Letra gerada automaticamente · sincronização estimada")
                        .font(.caption2).foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 22)
                }
                if transcribingAudio {
                    ProgressView("Transcrevendo áudio local…")
                        .tint(theme.accent)
                }
                if let transcriptionMessage {
                    Text(transcriptionMessage)
                        .font(.caption).foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 22)
                }

                if !inline && !lyricStore.lines.isEmpty {
                    HStack(spacing: 10) {
                        Text("SINCRONIA")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            lyricStore.userOffset -= 0.5
                        } label: {
                            Label("Atrasar", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Atrasar a legenda meio segundo")
                        Text(String(format: "%+.1fs", lyricStore.userOffset))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 44)
                        Button {
                            lyricStore.userOffset += 0.5
                        } label: {
                            Label("Adiantar", systemImage: "plus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Adiantar a legenda meio segundo")
                        if lyricStore.userOffset != 0 {
                            Button("Zerar") { lyricStore.userOffset = 0 }
                                .font(.caption2)
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(lyricAccent)
                    .padding(.horizontal, 22)
                }

                if loading && (lyricStore.trackID != track.id || lyricStore.lines.isEmpty) {
                    Spacer()
                    ProgressView("Buscando letras…")
                        .tint(theme.accent)
                        .foregroundStyle(.white)
                    Spacer()
                } else if lyricStore.trackID == track.id, !lyricStore.lines.isEmpty {
                    synchronizedLyrics
                } else if lyricStore.status == .searching {
                    Spacer()
                    ProgressView("Preparando guia vocal…")
                        .tint(theme.accent)
                        .foregroundStyle(.white)
                    Spacer()
                } else if let text = record?.plainLyrics, !text.isEmpty {
                    ScrollView {
                        Text(text)
                            .font(.title3.weight(.medium))
                            // Static lyrics also honor the Capa/Tema selection.
                            .foregroundStyle(lyricAccent)
                            .animation(.easeInOut(duration: 0.28), value: lyricAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, inline ? 32 : 24)
                            .padding(.vertical, 24)
                    }
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "Letra não confirmada",
                        systemImage: "music.mic",
                        description: Text(errorMessage ??
                            "Não encontramos uma letra que corresponda com segurança a esta música.")
                    )
                    .foregroundStyle(.white)
                    Button("Escolher letra manualmente") { isChoosingLyrics = true }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                    Button(action: generateAudioLyrics) {
                        Label("Gerar letra do áudio", systemImage: "waveform")
                    }
                    .disabled(transcribingAudio)
                    .accessibilityIdentifier("lyrics.generateFromAudio")
                    if transcribingAudio { ProgressView("Transcrevendo no iPhone…") }
                    if let transcriptionMessage {
                        Text(transcriptionMessage).font(.footnote).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                }
            }
            .padding(.top, inline ? 4 : 20)
        }
        .onAppear {
            if lyricStore.trackID != track.id { lyricStore.beginLoading(trackID: track.id) }
            lyricStore.attach(clock: audio.lyricsClock)
            lyricStore.seekHandler = { position in audio.seek(to: position) }
        }
        .onDisappear {
            lyricStore.seekHandler = nil
        }
        .task(id: track.id) {
            artworkTint = nil
            let sampled = await ArtworkTintExtractor.fetch(for: track)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.42)) {
                artworkTint = sampled
            }
        }
        .task(id: track.id) {
            loading = true
            errorMessage = nil
            transcriptionMessage = nil
            record = nil
            candidates = []
            manualCandidates = []
            manualHasSearched = false
            manualQuery = ""
            if let prefetcher {
                // Reutiliza a busca que começou durante a reprodução.
                let cached = await prefetcher.awaitChoice(for: track.id)
                guard !Task.isCancelled else { return }
                if let cached {
                    candidates = cached.alternatives.map(\.asLegacyRecord)
                    if let selected = cached.selected {
                        record = selected.asLegacyRecord
                        if let synced = selected.syncedLyrics, !synced.isEmpty {
                            lyricStore.load(trackID: track.id, rawLRC: synced,
                                            needsReview: cached.needsReview,
                                            force: cached.pinned)
                        } else if lyricStore.status != .ready,
                                  let url = audio.visualAnalysisURL {
                            lyricStore.loadFallback(trackID: track.id,
                                                    plainText: selected.plainLyrics,
                                                    sourceURL: url, duration: audio.duration)
                        }
                    } else {
                        errorMessage = "Preparando guia vocal local…"
                        if lyricStore.status != .ready,
                           let url = audio.visualAnalysisURL {
                            lyricStore.loadFallback(trackID: track.id, plainText: nil,
                                                    sourceURL: url, duration: audio.duration)
                        }
                    }
                    loading = false
                    return
                }
            }
            // Compatibilidade com faixa aberta antes do prefetcher existir.
            if lyricStore.trackID != track.id { lyricStore.clear() }
            do {
                let lookup = try await LyricsService.search(for: track,
                                                             audioDuration: audio.duration)
                try Task.checkCancellation()
                candidates = lookup.suggestions
                if let confirmed = lookup.automatic {
                    apply(confirmed)
                } else {
                    errorMessage = candidates.isEmpty
                        ? "Não encontramos letras para esta faixa. Pesquise manualmente."
                        : "Os resultados do LRCLIB não coincidem com a gravação. Escolha a letra correta."
                    if let url = audio.visualAnalysisURL {
                        lyricStore.loadFallback(trackID: track.id, plainText: nil,
                                                sourceURL: url, duration: audio.duration)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Não foi possível consultar o LRCLIB. Tente pesquisar a letra."
            }
            loading = false
        }
        .sheet(isPresented: $showLyricsControlCenter, onDismiss: {
            if queuedManualPicker {
                queuedManualPicker = false
                isChoosingLyrics = true
            }
        }) {
            LyricsControlCenter(
                theme: $theme,
                backgroundStyle: $backgroundStyle,
                colorMode: $colorMode,
                lyricsCleanMode: $lyricsCleanMode,
                currentRecord: record,
                needsReview: lyricStore.needsReview,
                artworkTint: artworkTint,
                hasSynchronizedLyrics: !lyricStore.lines.isEmpty,
                onChooseLyrics: {
                    queuedManualPicker = true
                    showLyricsControlCenter = false
                },
                onDismiss: { showLyricsControlCenter = false },
                audio: audio
            )
        }
        .sheet(isPresented: $isChoosingLyrics) {
            NavigationStack {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Artista e nome da música", text: $manualQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { manualSearchID = UUID() }
                        Button {
                            manualSearchID = UUID()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Pesquisar outra letra")
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)

                    if manualSearching {
                        ProgressView("Procurando correspondências…")
                    }
                    if let pickerError {
                        Text(pickerError).font(.caption).foregroundStyle(.secondary)
                    }
                    List((manualHasSearched ? manualCandidates : candidates).prefix(20)) { candidate in
                        Button {
                            apply(candidate, pin: true)
                            isChoosingLyrics = false
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.trackName)
                                    .font(.headline)
                                Text("\(candidate.artistName) · \(Int(candidate.duration))s" +
                                     (candidate.syncedLyrics == nil ? " · estática" : " · sincronizada"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .listStyle(.plain)
                }
                .navigationTitle("Escolher letra")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Fechar") { isChoosingLyrics = false }
                    }
                }
                .task(id: manualSearchID) {
                    let requestID = manualSearchID
                    let query = manualQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return }
                    manualSearching = true
                    manualHasSearched = true
                    manualCandidates = []
                    pickerError = nil
                    do {
                        let fetched = try await LyricsService.searchManually(query)
                        try Task.checkCancellation()
                        guard manualSearchID == requestID else { return }
                        manualCandidates = fetched
                        if fetched.isEmpty {
                            pickerError = "Nenhuma letra encontrada para esta pesquisa."
                        }
                    } catch {
                        guard !Task.isCancelled, manualSearchID == requestID else { return }
                        if let serverError = error as? LRCLIBRequestError {
                            pickerError = serverError.errorDescription
                        } else if let urlError = error as? URLError, urlError.code == .timedOut {
                            pickerError = "A busca demorou demais. Verifique a conexão e tente novamente."
                        } else {
                            pickerError = "A pesquisa falhou. Verifique a conexão e tente novamente."
                        }
                    }
                    if manualSearchID == requestID { manualSearching = false }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}
