import AVFoundation
import Foundation
import Observation
import QuartzCore

// MARK: - Contrato do relógio de áudio

/// Quem toca o áudio implementa isto. Leitura barata, sem alocação, thread-safe.
protocol PlaybackClock: AnyObject, Sendable {
    var isPlaying: Bool { get }
    var playbackSpeed: Double { get }
    /// Segundos na linha do tempo ORIGINAL do arquivo (não do tempo de parede).
    /// Com speed 1.3x, após 10 s reais isto vale ~13 s.
    var lyricTime: TimeInterval { get }
}

extension PlaybackClock {
    var playbackSpeed: Double { 1 }
}

// MARK: - Store

enum LyricsStatus: Equatable, Sendable { case idle, searching, ready, unavailable }

/// Vive no root do app (@State no App) e é injetado via .environment.
/// A sheet de karaokê só LÊ; fechar a sheet não destrói nada.
///
/// Isolamento de re-render: este objeto NÃO publica o tempo.
/// - `activeLineIndex` / `isPlaying` só mudam em transições discretas (poucas vezes por minuto).
/// - O preenchimento palavra-a-palavra roda dentro de um TimelineView, lendo `clock.lyricTime` direto.
/// - O Player não lê nenhuma propriedade daqui, então o Observation nunca o invalida.
@MainActor
@Observable
final class LyricsStore {
    typealias FallbackGenerator = @Sendable (URL, TimeInterval, [TimeInterval]) async -> [TimedLyricLine]
    @ObservationIgnored private let fallbackGenerator: FallbackGenerator

    @ObservationIgnored let scoring = KaraokeScoringSession()

    private(set) var trackID: String?
    private(set) var lines: [TimedLyricLine] = []
    private(set) var hasWordSync = false
    private(set) var status: LyricsStatus = .idle
    private(set) var needsReview = false
    private(set) var activeLineIndex: Int?
    private(set) var scrollAnchorLineID: Int? = 0
    private(set) var isPlaying = false

    /// Calibração do usuário (Bluetooth etc.). Positivo = letra adianta.
    var userOffset: TimeInterval = 0 {
        didSet {
            if userOffset.isFinite { offsetDefaults.set(userOffset, forKey: offsetKey) }
        }
    }

    @ObservationIgnored private let offsetDefaults: UserDefaults
    @ObservationIgnored private var offsetKey: String
    @ObservationIgnored private var outputRouteObserver: NSObjectProtocol?

    /// O Player define: toque numa linha -> seek.
    @ObservationIgnored var seekHandler: (@MainActor (TimeInterval) -> Void)?

    @ObservationIgnored var scoringPitchShift: (() -> Double)?

    @ObservationIgnored private var clock: PlaybackClock?
    @ObservationIgnored private var driver: DisplayLinkDriver?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var refinedCache: [String: (source: String, lines: [TimedLyricLine])] = [:]
    /// Called by the app's memory-warning owner. Active song state stays intact.
    func discardVolatileLyricCache() {
        refinedCache.removeAll(keepingCapacity: false)
    }
    @ObservationIgnored private var rawSource: String?
    @ObservationIgnored private var acousticRefinementKey: String?
    @ObservationIgnored private var latestDNA: SongDNA?
    @ObservationIgnored private var lastObservedTime: TimeInterval = 0

    init(offsetDefaults: UserDefaults = .standard, fallbackGenerator: FallbackGenerator? = nil) {
        self.fallbackGenerator = fallbackGenerator ?? { url, duration, bars in
            await AutoLyricsTranscriber.generate(vocalURL: url, duration: duration, bars: bars)
        }
        self.offsetDefaults = offsetDefaults
        self.offsetKey = Self.currentOffsetKey()
        let saved = offsetDefaults.double(forKey: offsetKey)
        self.userOffset = saved.isFinite ? min(1, max(-1, saved)) : 0
    }

    private static func currentOffsetKey() -> String {
        let uid = AVAudioSession.sharedInstance().currentRoute.outputs.first?.uid ?? "default"
        return "karaoke.lyricsOffset.\(uid)"
    }

    private func refreshOffsetForOutputRoute() {
        let key = Self.currentOffsetKey()
        guard key != offsetKey else { return }
        offsetKey = key
        let saved = offsetDefaults.double(forKey: key)
        userOffset = saved.isFinite ? min(1, max(-1, saved)) : 0
        syncNow()
    }

    // MARK: Contrato

    func attach(clock: PlaybackClock) { self.clock = clock }

    func seek(to time: TimeInterval) {
        seekHandler?(time)
        let offset = clock.map { sourceTimelineOffset(for: $0) } ?? 0
        scoring.seek(to: time + offset)
    }

    func sourceTimelineOffset(for clock: PlaybackClock) -> TimeInterval {
        userOffset * clock.playbackSpeed
    }

    /// O prefetcher começa o trabalho antes do utilizador entrar em Karaokê.
    func beginLoading(trackID: String) {
        if self.trackID == trackID { return }
        loadTask?.cancel()
        loadGeneration = UUID()
        rawSource = nil
        acousticRefinementKey = nil
        latestDNA = nil
        if trackID != self.trackID {
            scoring.resetForTrack()
            self.trackID = trackID
            lines = []
            activeLineIndex = nil
            scrollAnchorLineID = 0
            hasWordSync = false
            lastObservedTime = 0
        }
        status = .searching
        needsReview = false
    }

    func markUnavailable(trackID: String) {
        guard self.trackID == trackID else { return }
        loadTask?.cancel()
        loadGeneration = UUID()
        scoring.stop()
        status = .unavailable
        lines = []
        activeLineIndex = nil
        scrollAnchorLineID = 0
        hasWordSync = false
        needsReview = false
    }

    /// Cache-first, then utility-priority stem preparation and local speech.
    /// A later catalog result or track replacement cancels this task.
    func loadFallback(trackID: String, plainText: String?, sourceURL: URL,
                      duration: TimeInterval, force: Bool = false,
                      retryRecognition: Bool = false) {
        guard self.trackID == trackID, force || status != .ready else { return }
        loadTask?.cancel()
        loadGeneration = UUID()
        let generation = loadGeneration
        status = .searching
        let bars = latestDNA?.barTimestamps ?? []
        let generateFallback = fallbackGenerator
        let fingerprint = AutoLyricsTranscriber.fingerprint(source: sourceURL) +
            "|" + (plainText ?? "")
        loadTask = Task.detached(priority: .utility) { [weak self] in
            if let cached = await AutoLyricsCache.shared.load(trackID: trackID,
                                                               fingerprint: fingerprint),
               !retryRecognition || cached.contains(where: {
                   $0.provenance == .autoTranscribed }) {
                await self?.installFallback(cached, trackID: trackID, generation: generation)
                return
            }
            // Lyrics fallback must not trigger a full-track STFT or upload.
            let vocalURL = sourceURL
            let generated: [TimedLyricLine]
            if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let phrases = (try? AutoLyricsTranscriber.rhythmicCues(
                    vocalURL: vocalURL, duration: duration, bars: bars)) ?? []
                generated = Self.alignPlain(plainText, duration: duration,
                                            phrases: phrases, bars: bars)
            } else {
                generated = await generateFallback(vocalURL, duration, bars)
            }
            guard !Task.isCancelled else { return }
            await AutoLyricsCache.shared.save(generated, trackID: trackID,
                                              fingerprint: fingerprint)
            await self?.installFallback(generated, trackID: trackID, generation: generation)
        }
    }

    private func installFallback(_ generated: [TimedLyricLine], trackID: String, generation: UUID) {
        guard self.trackID == trackID, loadGeneration == generation,
              status != .ready, !generated.isEmpty else { return }
        lines = generated
        hasWordSync = generated.contains { $0.precision == .word }
        status = .ready
        needsReview = generated.contains { $0.provenance == .autoTranscribed }
        syncNow()
    }

    nonisolated static func alignPlain(_ text: String, duration: TimeInterval,
                                       phrases: [TimedLyricLine],
                                       bars: [TimeInterval]) -> [TimedLyricLine] {
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
        guard !paragraphs.isEmpty else {
            return AutoLyricsTranscriber.fallbackBars(duration: duration, bars: bars)
        }
        let step = max(0.1, duration / Double(paragraphs.count))
        let lines = paragraphs.enumerated().map { index, paragraph in
            let cue = phrases.indices.contains(index) ? phrases[index] : nil
            let start = cue?.start ?? Double(index) * step
            let end = cue?.end ?? min(duration, start + step)
            let tokens = paragraph.split(whereSeparator: \.isWhitespace).enumerated().map {
                WordSync(id: $0.offset, text: String($0.element), start: start,
                         end: max(end, start + 0.01), spaceAfter: true)
            }
            return TimedLyricLine(id: index, start: start, end: max(end, start + 0.01),
                                  words: tokens, precision: .line,
                                  provenance: .plainLine)
        }
        return LyricsAlignmentRefiner.refine(lines, barBeats: bars,
            vocalEnergy: phrases.map { (time: $0.start, value: 1.0) })
    }

    func loadIfCurrent(trackID: String, rawLRC: String,
                       needsReview: Bool = false, force: Bool = false) {
        guard self.trackID == trackID else { return }
        load(trackID: trackID, rawLRC: rawLRC, needsReview: needsReview, force: force)
    }

    /// force=true é usado pela seleção manual (pin); o automático não a substitui.
    func load(trackID: String, rawLRC: String,
              needsReview: Bool = false, force: Bool = false) {
        guard force || trackID != self.trackID || status != .ready else {
            syncNow()
            return
        }
        loadTask?.cancel()
        loadGeneration = UUID()
        let generation = loadGeneration
        scoring.stop()
        self.trackID = trackID
        rawSource = rawLRC
        acousticRefinementKey = nil
        self.needsReview = needsReview
        status = .searching
        lines = []
        activeLineIndex = nil
        scrollAnchorLineID = 0
        hasWordSync = false
        lastObservedTime = 0

        if let cached = refinedCache[trackID], cached.source == rawLRC {
            lines = cached.lines
            hasWordSync = cached.lines.contains { $0.precision == .word }
            status = cached.lines.isEmpty ? .unavailable : .ready
            syncNow()
            return
        }

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let refined: [TimedLyricLine]
            if let cached = await LyricsAlignmentCache.shared.load(
                trackID: trackID, source: rawLRC) {
                refined = cached
            } else {
                let parsed = rawLRC.contains("Dialogue:")
                    ? ASSKaraokeParser.parse(rawLRC) : EnhancedLRCParser.parse(rawLRC)
                refined = LyricsAlignmentRefiner.refine(parsed.lines)
                await LyricsAlignmentCache.shared.save(refined, trackID: trackID,
                                                       source: rawLRC)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.trackID == trackID, self.loadGeneration == generation else { return }
                self.refinedCache[trackID] = (source: rawLRC, lines: refined)
                self.lines = refined
                self.hasWordSync = refined.contains { $0.precision == .word }
                self.status = refined.isEmpty ? .unavailable : .ready
                self.syncNow()
            }
        }
    }

    func clear() {
        loadTask?.cancel()
        loadGeneration = UUID()
        rawSource = nil
        acousticRefinementKey = nil
        latestDNA = nil
        scoring.resetForTrack()
        trackID = nil; lines = []; activeLineIndex = nil; scrollAnchorLineID = 0; hasWordSync = false
        lastObservedTime = 0
        status = .idle; needsReview = false; isPlaying = false
    }

    /// Replaces only estimated words after cached rhythm evidence arrives.
    /// The parse and cache write stay off the main actor.
    func refineUsing(_ dna: SongDNA, sourceURL: URL? = nil) {
        latestDNA = dna
        guard let trackID, let rawSource, !lines.isEmpty,
              !dna.onsetTimestamps.isEmpty || !dna.beatTimestamps.isEmpty else { return }
        let key = dna.sourceRevision + ":\(dna.onsetTimestamps.count):\(dna.beatTimestamps.count)"
        guard acousticRefinementKey != key else { return }
        acousticRefinementKey = key
        Task.detached(priority: .utility) { [weak self] in
            let cacheSource = rawSource + "|" + key
            let refined: [TimedLyricLine]
            if let cached = await LyricsAlignmentCache.shared.load(
                trackID: trackID, source: cacheSource) {
                refined = cached
            } else {
                let parsed = rawSource.contains("Dialogue:")
                    ? ASSKaraokeParser.parse(rawSource) : EnhancedLRCParser.parse(rawSource)
                let vocalEnergy = sourceURL.flatMap {
                    try? StereoVocalEnergyAnalyzer.analyze($0)
                } ?? []
                refined = LyricsAlignmentRefiner.refine(parsed.lines,
                    onsets: dna.onsetTimestamps,
                    barBeats: dna.beatTimestamps + dna.barTimestamps,
                    vocalEnergy: vocalEnergy)
                await LyricsAlignmentCache.shared.save(refined, trackID: trackID,
                    source: cacheSource)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.trackID == trackID,
                      self.rawSource == rawSource,
                      self.acousticRefinementKey == key else { return }
                self.refinedCache[trackID] = (source: rawSource, lines: refined)
                self.lines = refined
                self.syncNow()
            }
        }
    }

    /// Chamar em onAppear da sheet.
    func startTracking() {
        guard driver == nil else { return }
        refreshOffsetForOutputRoute()
        outputRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshOffsetForOutputRoute() }
        }
        let d = DisplayLinkDriver { [weak self] in self?.syncNow() }
        driver = d
        d.start()
        syncNow()               // sincroniza imediatamente ao reabrir
    }

    /// Chamar em onDisappear. Para o CADisplayLink; o estado (lines) permanece.
    func stopTracking() {
        driver?.stop()
        driver = nil
        if let outputRouteObserver {
            NotificationCenter.default.removeObserver(outputRouteObserver)
            self.outputRouteObserver = nil
        }
    }

    // MARK: Tick (≤ 30 Hz, só escreve quando algo muda)

    private func syncNow() {
        guard let clock else { return }
        let playing = clock.isPlaying
        if playing != isPlaying { isPlaying = playing }

        let t = clock.lyricTime + sourceTimelineOffset(for: clock)
        scoring.advance(time: t, playing: playing, lines: lines, pitchShift: scoringPitchShift?() ?? 0)
        let idx = KaraokeStanzaCamera.stableIndex(
            candidate: lines.activeIndex(at: t), previous: activeLineIndex,
            time: t, previousTime: lastObservedTime, lines: lines)
        lastObservedTime = t
        if idx != activeLineIndex {
            KaraokePerformanceProbe.shared.activeLineChanged()
            activeLineIndex = idx
        }
    }
}

// MARK: - CADisplayLink sem retain cycle

@MainActor
private final class DisplayLinkDriver: NSObject {
    private var link: CADisplayLink?
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) { self.onTick = onTick }

    func start() {
        let l = CADisplayLink(target: self, selector: #selector(tick))
        // Só precisamos detectar troca de linha; o fill roda no TimelineView.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()   // solta o retain do target
        link = nil
    }

    @objc private func tick() { onTick() }
}
