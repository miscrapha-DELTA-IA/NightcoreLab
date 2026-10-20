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

    @ObservationIgnored let scoring = KaraokeScoringSession()

    private(set) var trackID: String?
    private(set) var lines: [TimedLyricLine] = []
    private(set) var hasWordSync = false
    private(set) var status: LyricsStatus = .idle
    private(set) var needsReview = false
    private(set) var activeLineIndex: Int?
    private(set) var isPlaying = false

    /// Calibração em segundos de tempo real (Bluetooth etc.). Positivo = letra adianta.
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

    init(offsetDefaults: UserDefaults = .standard) {
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

    func sourceTimelineOffset(for clock: PlaybackClock) -> TimeInterval {
        userOffset * clock.playbackSpeed
    }

    /// O prefetcher começa o trabalho antes do utilizador entrar em Karaokê.
    func beginLoading(trackID: String, clearExisting: Bool = false) {
        // A second observer joining this track must not cancel its parser.
        if trackID == self.trackID, !clearExisting { return }
        loadTask?.cancel()
        loadGeneration = UUID()
        if trackID != self.trackID || clearExisting {
            scoring.resetForTrack()
            self.trackID = trackID
            lines = []
            activeLineIndex = nil
            hasWordSync = false
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
        hasWordSync = false
        needsReview = false
    }

    /// Async producers cannot replace the track selected by the player.
    func loadIfCurrent(trackID: String, rawLRC: String,
                       needsReview: Bool = false, force: Bool = false) {
        guard self.trackID == trackID else { return }
        load(trackID: trackID, rawLRC: rawLRC, needsReview: needsReview, force: force)
    }

    func beginLoadingIfCurrent(trackID: String) {
        guard self.trackID == trackID else { return }
        beginLoading(trackID: trackID, clearExisting: true)
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
        self.needsReview = needsReview
        status = .searching
        lines = []
        activeLineIndex = nil
        hasWordSync = false

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = EnhancedLRCParser.parse(rawLRC)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.trackID == trackID,
                      self.loadGeneration == generation else { return }
                self.lines = parsed.lines
                self.hasWordSync = parsed.hasWordSync
                self.status = parsed.lines.isEmpty ? .unavailable : .ready
                self.syncNow()
            }
        }
    }

    /// An AI upgrade may arrive while the user is singing. Keep the current
    /// scoring timeline intact; the prefetch cache applies the new LRC on the
    /// next playback instead of ending the live run.
    @discardableResult
    func loadGenerated(trackID: String, rawLRC: String) -> Bool {
        guard self.trackID == trackID, scoring.mode == .off else { return false }
        load(trackID: trackID, rawLRC: rawLRC, needsReview: true, force: true)
        return true
    }

    func clear() {
        loadTask?.cancel()
        loadGeneration = UUID()
        scoring.resetForTrack()
        trackID = nil; lines = []; activeLineIndex = nil; hasWordSync = false
        status = .idle; needsReview = false; isPlaying = false
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
        let idx = lines.activeIndex(at: t)
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
