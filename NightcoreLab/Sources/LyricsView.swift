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

struct LyricsView: View {
    let track: Track
    let playbackTime: TimeInterval
    let isPlaying: Bool
    let dismiss: () -> Void

    @State private var record: LyricsRecord?
    @State private var loading = true
    @State private var errorMessage: String?

    private var lines: [LyricLine] { LRCParser.parse(record?.syncedLyrics ?? "") }
    private var currentIndex: Int? {
        lines.indices.last { lines[$0].time <= playbackTime }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cover = track.thumbnailURL {
                GeometryReader { geometry in
                    WebImage(url: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 55)
                        .overlay(.black.opacity(0.55))
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
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
                .padding(.horizontal, 20)

                if loading {
                    Spacer()
                    ProgressView("Buscando letras…").tint(.white).foregroundStyle(.white)
                    Spacer()
                } else if !lines.isEmpty {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 26) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(index == currentIndex ? .title.bold() : .title2.weight(.semibold))
                                        .foregroundStyle(.white.opacity(index == currentIndex ? 1 : 0.48))
                                        .blur(radius: index == currentIndex ? 0 : 0.7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                        .accessibilityAddTraits(index == currentIndex ? [.isSelected] : [])
                                }
                            }
                            .padding(.horizontal, 25)
                            .padding(.vertical, 90)
                        }
                        .onChange(of: currentIndex) { _, next in
                            guard let next else { return }
                            withAnimation(.easeInOut(duration: 0.4)) {
                                reader.scrollTo(next, anchor: .center)
                            }
                        }
                        .onAppear {
                            if let currentIndex { reader.scrollTo(currentIndex, anchor: .center) }
                        }
                    }
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
            loading = true
            errorMessage = nil
            record = nil
            do {
                record = try await LyricsService.fetch(for: track)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Não foi possível consultar o LRCLIB."
            }
            loading = false
        }
    }
}
