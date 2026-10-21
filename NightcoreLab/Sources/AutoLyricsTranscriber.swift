import AVFoundation
import CryptoKit
import Foundation
import Speech

actor AutoLyricsCache {
    static let shared = AutoLyricsCache()
    static let schemaVersion = 1
    private struct Payload: Codable {
        let schemaVersion: Int
        let sourceFingerprint: String
        let lines: [TimedLyricLine]
    }
    private let folder: URL
    init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        .appendingPathComponent("NightcoreAutoLyrics", isDirectory: true)) {
        self.folder = folder
    }
    private func file(_ trackID: String) -> URL {
        let hash = SHA256.hash(data: Data(trackID.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash)
    }
    func load(trackID: String, fingerprint: String) -> [TimedLyricLine]? {
        guard let data = try? Data(contentsOf: file(trackID).appendingPathExtension("json")),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion,
              payload.sourceFingerprint == fingerprint,
              !payload.lines.isEmpty else { return nil }
        return payload.lines
    }
    func save(_ lines: [TimedLyricLine], trackID: String, fingerprint: String) {
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = Payload(schemaVersion: Self.schemaVersion,
                              sourceFingerprint: fingerprint, lines: lines)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: file(trackID).appendingPathExtension("json"), options: .atomic)
        }
        let lrc = lines.map { line in
            let minute = Int(line.start) / 60
            let second = line.start - Double(minute * 60)
            let words = line.words.map { word in
                let m = Int(word.start) / 60
                let s = word.start - Double(m * 60)
                return String(format: "<%02d:%05.2f>%@%@", m, s, word.text,
                              word.spaceAfter ? " " : "")
            }.joined()
            return String(format: "[%02d:%05.2f]%@", minute, second, words)
        }.joined(separator: "\n")
        try? lrc.write(to: file(trackID).appendingPathExtension("lrc"),
                       atomically: true, encoding: .utf8)
    }
}

enum AutoLyricsTranscriber {
    struct TimedWord: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    static func fingerprint(source: URL) -> String {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(source.lastPathComponent)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    static func generate(vocalURL: URL, duration: TimeInterval,
                         bars: [TimeInterval], allowSpeechRecognition: Bool = true) async -> [TimedLyricLine] {
        if allowSpeechRecognition, SFSpeechRecognizer.authorizationStatus() == .authorized,
           let recognizer = SFSpeechRecognizer(locale: .current),
           recognizer.supportsOnDeviceRecognition,
           let words = await recognizeFullTrack(vocalURL, recognizer: recognizer),
           !words.isEmpty {
            return group(words, bars: bars)
        }
        return (try? rhythmicCues(vocalURL: vocalURL, duration: duration, bars: bars)) ??
            fallbackBars(duration: duration, bars: bars)
    }

    static func requestPermission() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    private static func recognize(_ url: URL,
                                  recognizer: SFSpeechRecognizer) async -> [TimedWord]? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard result?.isFinal == true || error != nil else { return }
                lock.lock()
                let shouldResume = !finished
                finished = true
                lock.unlock()
                guard shouldResume else { return }
                let words = result?.bestTranscription.segments.map {
                    TimedWord(text: $0.substring.trimmingCharacters(in: .whitespacesAndNewlines),
                              start: $0.timestamp,
                              end: $0.timestamp + $0.duration)
                }
                continuation.resume(returning: words)
            }
        }
    }

    /// Speech tasks are bounded to 45-second local CAF slices. This keeps
    /// long tracks from silently losing every verse after the first minute.
    private static func recognizeFullTrack(_ url: URL,
                                           recognizer: SFSpeechRecognizer) async -> [TimedWord]? {
        guard let file = try? AVAudioFile(forReading: url,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false) else { return nil }
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        if duration <= 45 { return await recognize(url, recognizer: recognizer) }
        let chunkFrames = AVAudioFramePosition(45 * rate)
        var words: [TimedWord] = []
        var start: AVAudioFramePosition = 0
        while start < file.length {
            if Task.isCancelled { return nil }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nightcore_speech_\(UUID().uuidString).caf")
            do {
                do {
                let writer = try AVAudioFile(forWriting: temp,
                    settings: file.processingFormat.settings,
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: 4096) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                file.framePosition = start
                let end = min(file.length, start + chunkFrames)
                while file.framePosition < end {
                    try Task.checkCancellation()
                    let remaining = end - file.framePosition
                    buffer.frameLength = AVAudioFrameCount(min(4096, remaining))
                    try file.read(into: buffer, frameCount: buffer.frameLength)
                    if buffer.frameLength == 0 { break }
                    try writer.write(from: buffer)
                }
                }
                let part = await recognize(temp, recognizer: recognizer) ?? []
                let offset = Double(start) / rate
                words += part.map { TimedWord(text: $0.text,
                                              start: $0.start + offset,
                                              end: $0.end + offset) }
            } catch { /* The rhythmic cue path remains available. */ }
            try? FileManager.default.removeItem(at: temp)
            start += chunkFrames
        }
        return words
    }

    static func group(_ words: [TimedWord], bars: [TimeInterval]) -> [TimedLyricLine] {
        let ordered = words.filter { !$0.text.isEmpty && $0.start.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return [] }
        var groups: [[TimedWord]] = [], current: [TimedWord] = []
        for word in ordered {
            if let last = current.last,
               word.start - last.end >= 0.45 || current.count >= 8 {
                groups.append(current); current = []
            }
            current.append(word)
            if current.count >= 4, let nextBar = bars.first(where: { $0 >= word.end }),
               nextBar - word.end <= 0.08 {
                groups.append(current); current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { index, group in
            let first = group[0], last = group[group.count - 1]
            let start = nearestBar(to: first.start, bars: bars) ?? first.start
            let end = max(last.end, (nearestBar(to: last.end, bars: bars) ?? last.end))
            let tokens = group.enumerated().map { offset, word in
                WordSync(id: offset, text: word.text,
                         start: max(0, word.start), end: max(word.start + 0.01, word.end),
                         spaceAfter: true)
            }
            return TimedLyricLine(id: index, start: max(0, min(start, first.start)),
                                  end: max(end, first.end), words: tokens,
                                  precision: .word, provenance: .autoTranscribed)
        }
    }

    private static func nearestBar(to time: TimeInterval,
                                   bars: [TimeInterval]) -> TimeInterval? {
        let nearest = bars.min { abs($0 - time) < abs($1 - time) }
        return nearest.flatMap { abs($0 - time) <= 0.12 ? $0 : nil }
    }

    /// An honest nonverbal guide when recognition is unavailable. It never
    /// presents guessed words as a transcription.
    static func rhythmicCues(vocalURL: URL, duration: TimeInterval,
                             bars: [TimeInterval]) throws -> [TimedLyricLine] {
        let file = try AVAudioFile(forReading: vocalURL, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: 4096) else { return fallbackBars(duration: duration, bars: bars) }
        var windows: [(TimeInterval, Double)] = []
        var framesRead: AVAudioFramePosition = 0
        while framesRead < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, file.length - framesRead)))
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channel = buffer.floatChannelData?[0] else { break }
            var sum = 0.0
            for i in 0..<count { sum += Double(channel[i] * channel[i]) }
            windows.append((Double(framesRead) / rate, sqrt(sum / Double(count))))
            framesRead += AVAudioFramePosition(count)
        }
        let peak = windows.map { $0.1 }.max() ?? 0
        let threshold = max(0.008, peak * 0.18)
        let active = windows.filter { $0.1 >= threshold }.map { $0.0 }
        guard !active.isEmpty else { return fallbackBars(duration: duration, bars: bars) }
        var ranges: [(Double, Double)] = []
        var start = active[0], end = active[0]
        for time in active.dropFirst() {
            if time - end >= 0.45 {
                ranges.append((start, end + 0.12)); start = time
            }
            end = time
        }
        ranges.append((start, end + 0.12))
        return ranges.enumerated().map { index, span in
            let from = max(0, nearestBar(to: span.0, bars: bars) ?? span.0)
            let to = min(duration, max(from + 0.1, span.1))
            return TimedLyricLine(id: index, start: from, end: to,
                words: [WordSync(id: 0, text: "♪", start: from, end: to, spaceAfter: false)],
                precision: .estimated, provenance: .rhythmicCue)
        }
    }

    static func fallbackBars(duration: TimeInterval, bars: [TimeInterval]) -> [TimedLyricLine] {
        let starts = bars.isEmpty ? stride(from: 0.0, to: max(1, duration), by: 4).map { $0 } : bars
        return starts.prefix(500).enumerated().map { index, start in
            let end = min(max(start + 0.2, duration), start + 2)
            return TimedLyricLine(id: index, start: start, end: end,
                words: [WordSync(id: 0, text: "♪", start: start, end: end, spaceAfter: false)],
                precision: .estimated, provenance: .rhythmicCue)
        }
    }
}
