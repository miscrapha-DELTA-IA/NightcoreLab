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

struct LyricsRecord: Decodable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let instrumental: Bool?
}

enum LyricsService {
    static func fetch(for track: Track) async throws -> LyricsRecord? {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != track.id else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        // The current Track contract has no artist field. Use the artist-title
        // convention where possible, otherwise perform a keyword search.
        let parts = title.components(separatedBy: " - ")
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            components.queryItems = [
                URLQueryItem(name: "artist_name", value: parts[0]),
                URLQueryItem(name: "track_name", value: parts[1])
            ]
        } else {
            components.queryItems = [URLQueryItem(name: "q", value: title)]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("NightcoreLab/1.0 (iOS lyrics viewer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let records = try JSONDecoder().decode([LyricsRecord].self, from: data)
        return records.first { !LRCParser.parse($0.syncedLyrics ?? "").isEmpty }
            ?? records.first { !($0.plainLyrics ?? "").isEmpty }
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !audio.isPlaying)) { _ in
            let span = max(end - start, 0.05)
            let fraction = min(max((audio.playbackTime - start) / span, 0), 1)
            Text(text)
                .font(.title.bold())
                .foregroundStyle(.white.opacity(0.4))
                .overlay(alignment: .leading) {
                    Text(text)
                        .font(.title.bold())
                        .foregroundStyle(accent)
                        // SwiftUI interpolates between the cover tint and Acid/Cyber/Crimson.
                        .animation(.easeInOut(duration: 0.42), value: accent)
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
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var artworkTint: ArtworkTint?
    @AppStorage("lyricsColorMode") private var colorMode: LyricsColorMode = .artwork

    private var lyricAccent: Color {
        switch colorMode {
        case .artwork: return artworkTint?.color ?? theme.accent
        case .theme: return theme.accent
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
                    .fill(mode == .artwork ? (artworkTint?.color ?? theme.accent) : theme.accent)
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
                                audio: audio
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
            // This small timeline drives only line changes. The scroll position
            // and the whole list are not re-evaluated on each animation frame.
            .overlay(alignment: .topLeading) {
                TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                    Color.clear.frame(width: 1, height: 1)
                        .onChange(of: lineIndex(at: audio.playbackTime), initial: true) { _, index in
                            guard activeIndex != index else { return }
                            activeIndex = index
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onAppear {
                activeIndex = lineIndex(at: audio.playbackTime)
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
                    Spacer(minLength: 4)
                    colorModeButton(.artwork)
                    colorModeButton(.theme)
                }
                .padding(.horizontal, 22)

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
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                } else {
                    Spacer()
                    ContentUnavailableView(
                        record?.instrumental == true ? "Faixa instrumental" : "Letra indisponível",
                        systemImage: "music.mic",
                        description: Text(errorMessage ?? "Não encontramos letras para esta faixa.")
                    )
                    .foregroundStyle(.white)
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
            activeIndex = nil
            do {
                let fetched = try await LyricsService.fetch(for: track)
                try Task.checkCancellation()
                record = fetched
                parsedLines = LRCParser.parse(fetched?.syncedLyrics ?? "")
                activeIndex = lineIndex(at: audio.playbackTime)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Não foi possível consultar o LRCLIB."
            }
            loading = false
        }
    }
}
