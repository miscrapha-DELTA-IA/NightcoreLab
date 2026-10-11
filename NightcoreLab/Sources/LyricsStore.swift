import Foundation
import Observation
import QuartzCore

// MARK: - Contrato do relógio de áudio

/// Quem toca o áudio implementa isto. Leitura barata, sem alocação, thread-safe.
protocol PlaybackClock: AnyObject, Sendable {
    var isPlaying: Bool { get }
    /// Segundos na linha do tempo ORIGINAL do arquivo (não do tempo de parede).
    /// Com speed 1.3x, após 10 s reais isto vale ~13 s.
    var lyricTime: TimeInterval { get }
}

// MARK: - Store

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

    private(set) var trackID: String?
    private(set) var lines: [TimedLyricLine] = []
    private(set) var hasWordSync = false
    private(set) var activeLineIndex: Int?
    private(set) var isPlaying = false

    /// Calibração do usuário (Bluetooth etc.). Positivo = letra adianta.
    var userOffset: TimeInterval = 0

    /// O Player define: toque numa linha -> seek.
    @ObservationIgnored var seekHandler: (@MainActor (TimeInterval) -> Void)?

    @ObservationIgnored private var clock: PlaybackClock?
    @ObservationIgnored private var driver: DisplayLinkDriver?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    // MARK: Contrato

    func attach(clock: PlaybackClock) { self.clock = clock }

    /// Idempotente por trackID: reabrir a sheet ou re-render não reparseia.
    func load(trackID: String, rawLRC: String) {
        guard trackID != self.trackID else { syncNow(); return }
        loadTask?.cancel()
        self.trackID = trackID
        lines = []
        activeLineIndex = nil
        hasWordSync = false

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let out = EnhancedLRCParser.parse(rawLRC)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.trackID == trackID else { return }
                self.lines = out.lines
                self.hasWordSync = out.hasWordSync
                self.syncNow()
            }
        }
    }

    func clear() {
        loadTask?.cancel()
        trackID = nil; lines = []; activeLineIndex = nil; hasWordSync = false; isPlaying = false
    }

    /// Chamar em onAppear da sheet.
    func startTracking() {
        guard driver == nil else { return }
        let d = DisplayLinkDriver { [weak self] in self?.syncNow() }
        driver = d
        d.start()
        syncNow()               // sincroniza imediatamente ao reabrir
    }

    /// Chamar em onDisappear. Para o CADisplayLink; o estado (lines) permanece.
    func stopTracking() {
        driver?.stop()
        driver = nil
    }

    // MARK: Tick (≤ 30 Hz, só escreve quando algo muda)

    private func syncNow() {
        guard let clock else { return }
        let playing = clock.isPlaying
        if playing != isPlaying { isPlaying = playing }

        let t = clock.lyricTime + userOffset
        let idx = lines.activeIndex(at: t)
        if idx != activeLineIndex { activeLineIndex = idx }
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