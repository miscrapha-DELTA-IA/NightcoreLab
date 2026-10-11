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

private struct ProgressiveLyricLine: View {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let accent: Color
    let audio: AudioEngineManager
    let syncOffset: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !audio.isPlaying)) { _ in
            let span = max(end - start, 0.05)
            let fraction = min(max((audio.playbackTime + syncOffset - start) / span, 0), 1)
            Text(text)
                .font(.title.bold())
                // The selected palette is visible even at progress 0 and while paused.
                .foregroundStyle(accent.opacity(0.38))
                .animation(.easeInOut(duration: 0.28), value: accent)
                .overlay(alignment: .leading) {
                    Text(text)
                        .font(.title.bold())
                        .foregroundStyle(accent)
                        // SwiftUI interpolates between the cover tint and Acid/Cyber/Crimson.
                        .animation(.easeInOut(duration: 0.28), value: accent)
                        .mask(alignment: .leading) {
                            GeometryReader { geometry in
                                let width = geometry.size.width
                                let revealed = width * fraction
                                // A subtle feathered edge inspired by KaraokeText's
                                // per-glyph sweep, without its iOS 18 dependency.
                                let feather = max(0, min(18, revealed, width - revealed))
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(.white)
                                        .frame(width: max(0, revealed - feather))
                                    LinearGradient(
                                        colors: [.white, .clear],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                    .frame(width: feather)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .shadow(color: .black.opacity(0.62), radius: 5, y: 2)
        }
    }
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
    let theme: AppTheme
    let dismiss: () -> Void

    @State private var record: LyricsRecord?
    @State private var parsedLines: [LyricLine] = []
    @State private var activeIndex: Int?
    @State private var candidates: [LyricsRecord] = []
    @State private var isChoosingLyrics = false
    @State private var manualQuery = ""
    @State private var manualSearchID = UUID()
    @State private var manualSearching = false
    @State private var pickerError: String?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var artworkTint: ArtworkTint?
    @State private var syncOffset: TimeInterval = 0
    @AppStorage("lyricsColorMode") private var colorMode: LyricsColorMode = .artwork

    private var lyricAccent: Color {
        switch colorMode {
        // If the artwork is grayscale/unavailable, use readable neutral white,
        // never the theme color; otherwise the two choices looked identical.
        case .artwork: return artworkTint?.color ?? .white
        case .theme: return theme.accent
        }
    }

    private var synchronizedTime: TimeInterval {
        audio.playbackTime + syncOffset
    }

    private func apply(_ selected: LyricsRecord) {
        record = selected
        parsedLines = LRCParser.parse(selected.syncedLyrics ?? "")
        syncOffset = 0
        activeIndex = lineIndex(at: synchronizedTime)
        errorMessage = nil
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

    private func lineIndex(at time: TimeInterval) -> Int? {
        // Binary search: O(log n) per clock tick, without reparsing the lyrics.
        var lower = 0
        var upper = parsedLines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if parsedLines[middle].time <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : nil
    }

    private var synchronizedLyrics: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(parsedLines.indices, id: \.self) { index in
                        let line = parsedLines[index]
                        let text = line.text.isEmpty ? "♪" : line.text
                        if index == activeIndex {
                            ProgressiveLyricLine(
                                text: text,
                                start: line.time,
                                end: index + 1 < parsedLines.count
                                    ? parsedLines[index + 1].time
                                    : max(audio.duration, line.time + 1),
                                accent: lyricAccent,
                                audio: audio,
                                syncOffset: syncOffset
                            )
                            .id(index)
                            .accessibilityAddTraits(.isSelected)
                        } else {
                            Text(text)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.5))
                                .blur(radius: 0.6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .padding(.horizontal, 25)
                .padding(.vertical, 90)
            }
            // Only the line index (not the whole lyrics list) is checked at 8 Hz.
            // Keeping this separate from the active row's 30 Hz fill avoids frame drops.
            .overlay(alignment: .topLeading) {
                TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                    Color.clear.frame(width: 1, height: 1)
                        .onChange(of: lineIndex(at: synchronizedTime), initial: true) { _, index in
                            guard activeIndex != index else { return }
                            activeIndex = index
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: syncOffset) { _, _ in
                activeIndex = lineIndex(at: synchronizedTime)
            }
            .onChange(of: parsedLines) { _, _ in
                activeIndex = lineIndex(at: synchronizedTime)
            }
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onAppear {
                activeIndex = lineIndex(at: synchronizedTime)
                if let activeIndex {
                    proxy.scrollTo(activeIndex, anchor: .center)
                }
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LyricsBackdrop(track: track)

            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    if let cover = track.thumbnailURL {
                        WebImage(url: cover)
                            .resizable()
                            .scaledToFill()
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

                if let record {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LETRA ENCONTRADA")
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
                } else if !loading {
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

                if !parsedLines.isEmpty {
                    HStack(spacing: 10) {
                        Text("SINCRONIA")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            syncOffset -= 0.5
                        } label: {
                            Label("Atrasar", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Atrasar a legenda meio segundo")
                        Text(String(format: "%+.1fs", syncOffset))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 44)
                        Button {
                            syncOffset += 0.5
                        } label: {
                            Label("Adiantar", systemImage: "plus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Adiantar a legenda meio segundo")
                        if syncOffset != 0 {
                            Button("Zerar") { syncOffset = 0 }
                                .font(.caption2)
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(lyricAccent)
                    .padding(.horizontal, 22)
                }

                if loading {
                    Spacer()
                    ProgressView("Buscando letras…")
                        .tint(theme.accent)
                        .foregroundStyle(.white)
                    Spacer()
                } else if !parsedLines.isEmpty {
                    synchronizedLyrics
                } else if let text = record?.plainLyrics, !text.isEmpty {
                    ScrollView {
                        Text(text)
                            .font(.title3.weight(.medium))
                            // Static lyrics also honor the Capa/Tema selection.
                            .foregroundStyle(lyricAccent)
                            .animation(.easeInOut(duration: 0.28), value: lyricAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
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
                    Spacer()
                }
            }
            .padding(.top, 20)
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
            record = nil
            parsedLines = []
            candidates = []
            activeIndex = nil
            syncOffset = 0
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
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Não foi possível consultar o LRCLIB. Tente pesquisar a letra."
            }
            loading = false
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
                    List(candidates.prefix(20)) { candidate in
                        Button {
                            apply(candidate)
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
                    let query = manualQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return }
                    manualSearching = true
                    pickerError = nil
                    do {
                        let fetched = try await LyricsService.searchManually(query)
                        try Task.checkCancellation()
                        candidates = fetched
                        if fetched.isEmpty { pickerError = "Nenhuma letra encontrada para esta pesquisa." }
                    } catch {
                        guard !Task.isCancelled else { return }
                        pickerError = "A pesquisa falhou. Tente novamente."
                    }
                    manualSearching = false
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}
