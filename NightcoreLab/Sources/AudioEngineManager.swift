import AVFoundation
import AudioToolbox
import MediaPlayer
import Observation
import UniformTypeIdentifiers
import OSLog

// MARK: - Tipos de apoio

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, wav
    var id: String { rawValue }
    var qualityDescription: String {
        switch self {
        case .m4a: return "AAC · 320 kb/s · arquivo compacto"
        case .wav: return "WAV · PCM 24-bit · sem compressão com perdas"
        }
    }
}

enum AudioEngineError: LocalizedError {
    case noFileLoaded
    case bufferAllocationFailed
    case renderFailed
    case unsupportedAudio
    case exportInProgress

    var errorDescription: String? {
        switch self {
        case .noFileLoaded:            return "Nenhuma música carregada."
        case .bufferAllocationFailed:  return "Não foi possível alocar o buffer de áudio."
        case .renderFailed:            return "Falha ao renderizar o áudio."
        case .unsupportedAudio:        return "Áudio inválido ou não suportado. Importe MP3, M4A, WAV ou AIFF."
        case .exportInProgress:        return "Aguarde a exportação atual terminar."
        }
    }
}

/// Snapshot dos parâmetros usados no export offline (Sendable para cruzar threads).
struct RenderSettings: Sendable {
    let speed: Float
    let pitch: Float
    let reverb: Float
    let bass: Float
    let reverbPresetRaw: Int
}

struct StoryAudioSource: Sendable {
    let url: URL
    let settings: RenderSettings
}

// MARK: - AudioEngineManager

@MainActor
@Observable
final class AudioEngineManager {

    // Faixas válidas (alinhadas aos limites da extensão de PC, para não estourar a mixagem)
    static let speedRange: ClosedRange<Float>  = 0.5...2.0
    static let pitchRange: ClosedRange<Float>  = -1200...1200
    static let reverbRange: ClosedRange<Float> = 0...50   // wet/dry em %
    static let bassRange: ClosedRange<Float>   = 0...12   // ganho do low shelf em dB

    // Pipeline de masterização
    static let bassFrequency: Float = 120.0                // reforço de graves sem invadir tanto os médios
    static let bassBandwidth: Float = 1.0                  // oitavas
    static let defaultReverbPreset: AVAudioUnitReverbPreset = .mediumHall   // decay mais próximo dos 2 s da extensão
    static let outputHeadroomDB: Float = -1.5              // margem de saída; não é medição true-peak
    static let limiterAttack: Float = 0.003                // s
    static let limiterRelease: Float = 0.08                // s
    /// Sobreposição do algoritmo de time-stretch (3…32, padrão 8). Mais alto = menos
    /// artefatos metálicos ao acelerar/desacelerar, com um pouco mais de CPU.
    static let timePitchOverlap: Float = 16

    // Estado observável pela UI
    private(set) var isPlaying = false
    private(set) var playbackCompletionCount = 0
    private(set) var fileName: String?
    /// Ephemeral identity: changes every time the loaded source is replaced.
    /// Never serialized with events or exported as a private file path.
    private(set) var playbackSourceRevision = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0

    private(set) var speed: Float = 1.0
    private(set) var pitch: Float = 0
    private(set) var reverb: Float = 0
    private(set) var bass: Float = 0

    // Grafo de áudio (masterização):
    // player → upmix → varispeed → timePitch (só quando necessário) → EQ → reverb → limiter → saída
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    @ObservationIgnored lazy var lyricsClock = EnginePlaybackClock(player: player)
    private let upmix = AVAudioMixerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let timePitch = AudioEngineManager.makeTimePitch()
    private let bassEQ = AudioEngineManager.makeBassEQ()
    private let reverbNode = AudioEngineManager.makeReverb()
    private let limiter = AudioEngineManager.makeLimiter()
    /// Additive pad bus joins the music AFTER song DSP, BEFORE the peak limiter.
    /// Only the existing live AVAudioEngine produces sound.
    private let performanceMixer = AVAudioMixerNode()
    @ObservationIgnored private let padRuntime = PadAudioRuntime()
    /// A bounded foreground lease: while the playable pad deck is visible,
    /// do not cold-stop the sole AVAudioEngine between fingerdrumming hits.
    @ObservationIgnored private var performanceModePresented = false
    /// Cached per audio route; never query AVAudioSession on a pad trigger.
    @ObservationIgnored private var performanceOutputLatency: TimeInterval = 0
    /// Opt-in local metrics; no per-hit Observable notifications.
    @ObservationIgnored let padLatencyProbe = PadLatencyProbe()
    @ObservationIgnored private var padHitMicroVariation = PadHitMicroVariation()

    /// Runs on a direct pad touch, without AVAudioSession calls, PCM work or
    /// SwiftUI state changes. The returned velocity must also be recorded.
    func expressivePadVelocity(_ padID: String, velocity: Float,
                               touchEventUptime: TimeInterval) -> Float {
        padHitMicroVariation.velocity(
            for: padID, requested: velocity, at: touchEventUptime)
    }

    var performanceKit: PadKit { padRuntime.kit }
    var performanceSourceClip: PerformanceSourceClip? { padRuntime.sourceClip }
    var performancePadsReady: Bool { padRuntime.isReady }

    /// Ordem da cadeia, usada para attach e para desconectar ao trocar de música.
    private var processingNodes: [AVAudioNode] {
        [player, upmix, varispeed, timePitch, bassEQ, reverbNode, performanceMixer, limiter]
    }

    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var sourceURL: URL?
    /// Read-only source for opt-in utility-priority visual analysis.
    /// No audio node or tap is installed.
    var visualAnalysisURL: URL? { sourceURL }
    @ObservationIgnored private var needsScheduling = true
    @ObservationIgnored private var scheduleGeneration = 0
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private weak var remoteRelay: RemotePlaybackRelay?
    @ObservationIgnored private var remoteCanSkipNext = false
    @ObservationIgnored private var remoteCanSkipPrevious = false
    @ObservationIgnored private var interruptedSourceURL: URL?
    @ObservationIgnored private var lastKnownTime: TimeInterval = 0
    @ObservationIgnored private var scheduledStartTime: TimeInterval = 0

    @ObservationIgnored private var idleStopTask: Task<Void, Never>?
    @ObservationIgnored private var idleStopGeneration = 0
    private let idleStopDelay: Duration
    private let transportSignposter = OSSignposter(
        subsystem: "com.nightcorelab.app", category: "AudioTransport")
    var isAudioEngineRunning: Bool { engine.isRunning }

    init(idleStopDelay: Duration = .seconds(10)) {
        self.idleStopDelay = max(.zero, idleStopDelay)
        clearTempAudioFiles()
        configureSession()
        setupEngine()
        observeInterruptions()
        setupRemoteTransportControls()
    }

    /// Anexa a cadeia de masterização e aplica os valores iniciais dos controles.
    /// As conexões são feitas em `load(url:)`, quando o formato do arquivo é conhecido.
    private func setupEngine() {
        processingNodes.forEach { engine.attach($0) }
        padRuntime.attach(to: engine)
        // Pads can sound before a song has been selected.
        let standaloneFormat = AVAudioFormat(
            standardFormatWithSampleRate: PadSampleSynthesizer.sampleRate, channels: 2)!
        engine.connect(performanceMixer, to: limiter, format: standaloneFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: standaloneFormat)
        padRuntime.connect(to: engine, mixer: performanceMixer)
        engine.mainMixerNode.outputVolume = pow(10, Self.outputHeadroomDB / 20)
        engine.prepare()

        Self.configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: speed, pitch: pitch)
        bassEQ.bands[0].gain = bass
        reverbNode.wetDryMix = reverb
    }

    // MARK: Carregar arquivo

    func load(url: URL) throws {
        interruptedSourceURL = nil // A replacement must never resume a prior source.
        // Core Audio decodifica MP3/AAC para PCM float; não há conversão com perdas na importação.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              (1...2).contains(file.processingFormat.channelCount) else {
            throw AudioEngineError.unsupportedAudio
        }
        stopPlayback()
        audioFile = file
        sourceURL = url
        playbackSourceRevision &+= 1
        fileName = url.deletingPathExtension().lastPathComponent
        duration = Double(file.length) / file.processingFormat.sampleRate

        engine.stop()
        padRuntime.clearSourceClip()
        processingNodes.forEach { engine.disconnectNodeOutput($0) }
        (padRuntime.nodes + padRuntime.releaseNodes).forEach {
            engine.disconnectNodeOutput($0)
        }

        let graphFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate,
                                        channels: 2)!
        Self.connectGraph(engine: engine, player: player, upmix: upmix,
                          varispeed: varispeed, timePitch: timePitch, eq: bassEQ, reverb: reverbNode, limiter: limiter,
                          fileFormat: file.processingFormat, graphFormat: graphFormat,
                          performanceMixer: performanceMixer)
        padRuntime.connect(to: engine, mixer: performanceMixer)
        engine.prepare()
        if performanceModePresented {
            do {
                try engine.start()
                padRuntime.primeVoices()
            } catch {
                // The next pad attempt can retry if an interruption stopped it.
            }
        }
        needsScheduling = true
        scheduledStartTime = 0
        lastKnownTime = 0
        setupNowPlaying()
    }

    // MARK: Performance pads

    /// Prewarm the EXISTING shared engine when entering Performance Mode.
    /// Its first-start cost occurs on opening the instrument instead of the
    /// first musical hit. The lease exists only while the sheet is shown.
    func beginPerformanceMode() {
        guard !performanceModePresented else { return }
        performanceModePresented = true
        refreshPerformanceOutputLatency()
        cancelIdleStop()
        if !engine.isRunning { try? engine.start() }
        if engine.isRunning { padRuntime.primeVoices() }
    }

    /// Restore the normal energy policy when the instrument is dismissed.
    /// Playback continues normally if a source song is still running.
    func endPerformanceMode() {
        guard performanceModePresented else { return }
        performanceModePresented = false
        padRuntime.stopAll()
        if !isPlaying { scheduleIdleStop() }
    }

    /// Cached, bounded source-time for recorded pads. The rendered music
    /// time leads what the user hears by output latency; speed converts the
    /// latency back to original song seconds. This is NOT EnginePlaybackClock
    /// lyricTime (which already compensates independently).
    func recordedPadSourceTime() -> TimeInterval? {
        guard isPlaying else { return nil }
        let compensation = performanceOutputLatency * Double(speed)
        return min(duration, max(0, currentTime - compensation))
    }

    private func refreshPerformanceOutputLatency() {
        let latency = AVAudioSession.sharedInstance().outputLatency
        performanceOutputLatency = latency.isFinite ?
            min(0.35, max(0, latency)) : 0
    }

    /// Prepare at most five seconds from the currently loaded local source.
    /// Decode/resample is off the main actor; no disk IO on the pad's touch path.
    /// A source swap during preparation invalidates the result atomically.
    func assignPerformanceSourceClip(startTime: TimeInterval, duration: TimeInterval,
                                     expectedRevision: Int) async throws -> PerformanceSourceClip {
        guard !isExporting, playbackSourceRevision == expectedRevision,
              let sourceURL, sourceURL.isFileURL,
              let clip = PerformanceSourceClip(
                startTime: startTime, duration: duration, sourceDuration: self.duration) else {
            throw AudioEngineError.unsupportedAudio
        }
        let capturedURL = sourceURL
        let pcm = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try PerformanceClipExtractor.decode(from: capturedURL, clip: clip)
            try Task.checkCancellation()
            return data
        }.value
        try Task.checkCancellation()
        guard playbackSourceRevision == expectedRevision, self.sourceURL == capturedURL,
              padRuntime.installSourceClip(clip, pcm: pcm) else {
            throw AudioEngineError.unsupportedAudio
        }
        return clip
    }

    /// Fast path: buffers and voice nodes were already created. Does not
    /// read files, reconfigure DSP or inspect lyrics when tapping a pad.
    @discardableResult
    func triggerPad(_ padID: String, velocity: Float = 0.85,
                    touchEventUptime: TimeInterval? = nil) -> Bool {
        let profiling = padLatencyProbe.isCapturing
        let began = profiling ? ProcessInfo.processInfo.systemUptime : 0
        guard !isExporting, padRuntime.isReady,
              padRuntime.descriptor(for: padID) != nil,
              velocity.isFinite && velocity > 0 else {
            if profiling {
                padLatencyProbe.record(.init(
                    touchToHandlerMS: nil, touchToCommandMS: nil,
                    commandMS: 0, engineStartMS: 0, nodeStopMS: 0,
                    nodeScheduleMS: 0, nodePlayMS: 0,
                    wasCold: !engine.isRunning, succeeded: false))
            }
            return false
        }
        let wasCold = !engine.isRunning
        var engineStartMS = 0.0
        var nodeTiming = PadNodeDispatchTiming(stopMS: 0, scheduleMS: 0, playMS: 0)
        if !performanceModePresented { cancelIdleStop() }
        var played = false
        // Capture the audio-command boundary BEFORE idle-stop task work.
        // This timer is unrelated to when node.play() has been submitted.
        var commandCompletedAt = began
        do {
            if wasCold {
                let start = profiling ? ProcessInfo.processInfo.systemUptime : 0
                try engine.start()
                if performanceModePresented { padRuntime.primeVoices() }
                if profiling {
                    engineStartMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                }
            }
            if profiling {
                played = padRuntime.trigger(padID: padID, velocity: velocity) {
                    nodeTiming = $0
                }
            } else {
                played = padRuntime.trigger(padID: padID, velocity: velocity)
            }
            if profiling { commandCompletedAt = ProcessInfo.processInfo.systemUptime }
            if !isPlaying && !performanceModePresented { scheduleIdleStop() }
        } catch {
            if profiling { commandCompletedAt = ProcessInfo.processInfo.systemUptime }
            if !isPlaying && !performanceModePresented { scheduleIdleStop() }
        }
        if profiling {
            let inputDelay = touchEventUptime.flatMap { event -> Double? in
                let ms = (began - event) * 1_000
                // OS event timestamps and uptime use the same monotonic origin.
                // Drop obviously invalid/discontinuous observations.
                return ms.isFinite && ms >= 0 && ms < 2_000 ? ms : nil
            }
            let commandElapsedMS = PadLatencyProbe.elapsedMilliseconds(
                from: began, to: commandCompletedAt)
            padLatencyProbe.record(.init(
                touchToHandlerMS: inputDelay,
                touchToCommandMS: inputDelay.map { $0 + commandElapsedMS },
                commandMS: commandElapsedMS,
                engineStartMS: engineStartMS,
                nodeStopMS: nodeTiming.stopMS,
                nodeScheduleMS: nodeTiming.scheduleMS,
                nodePlayMS: nodeTiming.playMS,
                wasCold: wasCold, succeeded: played))
        }
        return played
    }

    func stopPerformancePads() {
        padRuntime.stopAll()
        if !isPlaying && !performanceModePresented { scheduleIdleStop() }
    }

    // MARK: Transporte

    func play() {
        guard let file = audioFile else { return }
        cancelIdleStop()
        let interval = transportSignposter.beginInterval("Audio resume")
        defer { transportSignposter.endInterval("Audio resume", interval) }
        do {
            if !engine.isRunning { try engine.start() }
            if performanceModePresented { padRuntime.primeVoices() }
            if needsScheduling {
                // Preserve the existing replay-from-start behavior at EOF.
                if lastKnownTime >= duration { lastKnownTime = 0 }
                schedule(file, startingAt: lastKnownTime)
            }
            lyricsClock.refreshOutputLatency()
            player.play()
            interruptedSourceURL = nil
            isPlaying = true
            setupNowPlaying()
        } catch {
            print("AudioEngineManager: falha ao iniciar engine – \(error)")
        }
    }

    func pause() {
        guard audioFile != nil else { return }
        interruptedSourceURL = nil // Manual pause invalidates pending auto-resume.
        lastKnownTime = currentTime   // captura antes de pausar, enquanto lastRenderTime é válido
        lyricsClock.didPause(at: lastKnownTime)
        player.pause()
        isPlaying = false
        setupNowPlaying()
        scheduleIdleStop()
    }

    private func cancelIdleStop() {
        idleStopGeneration &+= 1
        idleStopTask?.cancel()
        idleStopTask = nil
    }

    private func scheduleIdleStop() {
        cancelIdleStop()
        guard !performanceModePresented else { return }
        let generation = idleStopGeneration
        let deadline = ContinuousClock.now.advanced(by: idleStopDelay)
        idleStopTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self,
                  generation == self.idleStopGeneration,
                  !self.isPlaying, !self.performanceModePresented else { return }
            // Capture happened at pause/seek, before invalidating node time.
            self.scheduleGeneration += 1
            self.player.stop()
            self.engine.stop()
            self.needsScheduling = true
            self.scheduledStartTime = self.lastKnownTime
            self.lyricsClock.didPause(at: self.lastKnownTime)
            self.idleStopTask = nil
            self.transportSignposter.emitEvent("Audio idle stop")
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Posição em segundos da fonte original para visualização do scrubber.
    var playbackTime: TimeInterval { currentTime }

    /// Seek absoluto, preservando o estado de reprodução e a cadeia DSP.
    func seek(to seconds: TimeInterval) {
        guard let file = audioFile, duration > 0, seconds.isFinite else { return }
        let target = min(max(seconds, 0), duration)
        let shouldResume = isPlaying
        scheduleGeneration += 1
        player.stop()
        isPlaying = false
        lastKnownTime = target
        lyricsClock.didSeek(to: target)
        scheduledStartTime = target
        needsScheduling = true
        if target < duration {
            schedule(file, startingAt: target)
            if shouldResume {
                play()
            }
        }
        setupNowPlaying()
    }

    /// Seek relativo usado pelo gesto horizontal do cartão.
    func seek(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    // MARK: Parâmetros em tempo real

    func setSpeed(_ value: Float) {
        speed = value.clamped(to: Self.speedRange)
        Self.configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: speed, pitch: pitch)
        lyricsClock.setSpeed(Double(speed))
        setupNowPlaying()   // a barra de progresso da tela de bloqueio acompanha a nova velocidade
    }

    func setPitch(_ value: Float) {
        pitch = value.clamped(to: Self.pitchRange)
        Self.configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: speed, pitch: pitch)
    }

    /// Atualiza velocidade e tom juntos, sem passar por um estado intermediário audível.
    func setPlayback(speed value: Float, keepOriginalPitch: Bool) {
        speed = value.clamped(to: Self.speedRange)
        pitch = keepOriginalPitch ? 0 : 1200 * log2(speed)
        Self.configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: speed, pitch: pitch)
        lyricsClock.setSpeed(Double(speed))
        setupNowPlaying()
    }

    func setReverb(_ value: Float) {
        reverb = value.clamped(to: Self.reverbRange)
        reverbNode.wetDryMix = reverb
        reverbNode.bypass = reverb == 0
    }

    /// Ganho do low shelf em 120 Hz, de 0 a 12 dB. Só o ganho muda; tipo, frequência
    /// e largura ficam fixos. A compensação evita empurrar todo o reforço para o limiter.
    func setBass(_ value: Float) {
        bass = value.clamped(to: Self.bassRange)
        bassEQ.bands[0].gain = bass
        bassEQ.globalGain = -bass
    }

    // MARK: Export offline

    /// Renderiza a música inteira com os parâmetros atuais (mais rápido que tempo real)
    /// e devolve a URL do arquivo no diretório temporário.
    func exportAudio(format: ExportFormat = .m4a) async throws -> URL {
        guard let sourceURL else { throw AudioEngineError.noFileLoaded }
        guard !isExporting else { throw AudioEngineError.exportInProgress }

        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        let settings = RenderSettings(speed: speed, pitch: pitch, reverb: reverb, bass: bass,
                                      reverbPresetRaw: Self.defaultReverbPreset.rawValue)
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.exportProgress = value }
        }

        let url = try await Task.detached(priority: .userInitiated) {
            try Self.renderOffline(source: sourceURL, settings: settings,
                                   format: format, progress: progress)
        }.value

        exportProgress = 1
        return url
    }

    /// Frozen additive pad-event export reuses the same offline music graph.
    /// The live engine remains untouched. No export is started by a pad tap.
    func exportPerformanceAudio(timeline: PerformanceTimeline,
                                format: ExportFormat = .m4a) async throws -> URL {
        guard let sourceURL else { throw AudioEngineError.noFileLoaded }
        guard !isExporting, timeline.isValid,
              timeline.kitID == padRuntime.kit.id else {
            throw AudioEngineError.exportInProgress
        }
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        let settings = RenderSettings(speed: speed, pitch: pitch, reverb: reverb,
                                      bass: bass, reverbPresetRaw: Self.defaultReverbPreset.rawValue)
        let task = Task.detached(priority: .userInitiated) {
            try Self.renderOffline(source: sourceURL, settings: settings,
                                   format: format, progress: { _ in },
                                   performance: timeline)
        }
        let url = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        exportProgress = 1
        return url
    }

    /// Capture the source and DSP values synchronously when the user taps Share.
    /// A later track change cannot alter the sound of an in-flight Story.
    func storyAudioSource() throws -> StoryAudioSource {
        guard let sourceURL else { throw AudioEngineError.noFileLoaded }
        let settings = RenderSettings(speed: speed, pitch: pitch, reverb: reverb, bass: bass,
                                      reverbPresetRaw: Self.defaultReverbPreset.rawValue)
        return StoryAudioSource(url: sourceURL, settings: settings)
    }

    /// Standalone offline graph. Does not seek, pause or replace the live player.
    nonisolated static func exportStorySegment(source: StoryAudioSource,
                                               startTime: TimeInterval,
                                               duration: TimeInterval) async throws -> URL {
        let renderTask = Task.detached(priority: .userInitiated) {
            try Self.renderOffline(source: source.url, settings: source.settings,
                                   format: .m4a, progress: { _ in },
                                   startTime: startTime, maxDuration: duration)
        }
        // Detached tasks do not inherit cancellation automatically.
        // Pressing Cancel must stop offline DSP rather than leaving the CPU busy.
        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    // MARK: - Privado: playback

    private func schedule(_ file: AVAudioFile, startingAt start: TimeInterval = 0) {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        let startFrame = min(max(AVAudioFramePosition(start * file.processingFormat.sampleRate), 0), file.length)
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        scheduledStartTime = start
        lyricsClock.didSeek(to: start)
        player.scheduleSegment(file, startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(min(remaining, Int64(UInt32.max))),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.playbackFinished(generation: generation) }
        }
        needsScheduling = false
    }

    private func playbackFinished(generation: Int) {
        // Ignora callbacks de agendamentos antigos (stop() também dispara o callback).
        guard generation == scheduleGeneration else { return }
        player.stop()
        // Pads are an independent performance surface: ending the song must
        // not choke a cymbal or 808 that the user is still hearing.
        needsScheduling = true
        isPlaying = false
        lastKnownTime = 0
        scheduledStartTime = 0
        lyricsClock.didSeek(to: 0)
        setupNowPlaying()
        scheduleIdleStop()
        playbackCompletionCount += 1
    }

    private func stopPlayback() {
        cancelIdleStop()
        scheduleGeneration += 1
        player.stop()
        needsScheduling = true
        isPlaying = false
        lastKnownTime = 0
        scheduledStartTime = 0
        lyricsClock.didSeek(to: 0)
    }

    // MARK: - Now Playing (Tela de Bloqueio / Control Center)

    /// Posição atual em segundos da música original (antes do speed).
    private var currentTime: TimeInterval {
        guard isPlaying else { return lastKnownTime }
        guard !needsScheduling,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return lastKnownTime
        }
        let seconds = scheduledStartTime + Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(max(seconds, 0), duration)
    }

    /// Publica título, duração, posição e estado de play/pause no sistema.
    /// O iOS anima a barra sozinho usando `PlaybackRate`, então basta chamar
    /// nas mudanças de estado (play, pause, fim, nova velocidade).
    func setupNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()

        guard let fileName else {
            center.nowPlayingInfo = nil
            return
        }

        // Duração e posição em tempo da música original; o rate = speed faz a barra
        // andar na velocidade certa (ex.: 1.25× termina 20% mais cedo).
        let elapsed = isPlaying ? currentTime : lastKnownTime
        let mode = speed > 1.001 ? "Nightcore" : (speed < 0.999 ? "Slowed" : "Original")

        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: fileName,
            MPMediaItemPropertyArtist: "\(mode) · \(String(format: "%.2f×", speed))",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        updateRemoteCommandAvailability()
    }

    /// SwiftUI owns the relay. The engine's weak link avoids retaining a view
    /// through its callbacks. Removing the relay disables navigational controls.
    func connectRemoteCommands(_ relay: RemotePlaybackRelay?) {
        remoteRelay = relay
        updateRemoteCommandAvailability()
    }

    /// Only enable actions backed by the current queue/navigation and audio.
    /// Previous is available for restart-from-zero even without older tracks.
    func updateRemoteCommandAvailability(canSkipNext: Bool? = nil,
                                         canSkipPrevious: Bool? = nil) {
        if let canSkipNext { remoteCanSkipNext = canSkipNext }
        if let canSkipPrevious { remoteCanSkipPrevious = canSkipPrevious }
        let commands = MPRemoteCommandCenter.shared()
        let available = fileName != nil && !isExporting
        commands.playCommand.isEnabled = available
        commands.pauseCommand.isEnabled = available
        commands.togglePlayPauseCommand.isEnabled = available
        commands.changePlaybackPositionCommand.isEnabled =
            available && duration > 0 && remoteRelay != nil
        commands.nextTrackCommand.isEnabled =
            available && remoteCanSkipNext && remoteRelay != nil
        commands.previousTrackCommand.isEnabled =
            available && remoteCanSkipPrevious && remoteRelay != nil
    }

    private func setupRemoteTransportControls() {
        let commands = MPRemoteCommandCenter.shared()

        // These targets are registered exactly once, at AudioEngineManager init.
        // MPRemote callbacks are delivered outside our actor; commands are
        // enqueued onto MainActor, then PlaybackCoordinator reconciles results.
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let relay = self.remoteRelay { _ = relay.dispatch(.play) }
                else { self.play() }
            }
            return .success
        }

        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let relay = self.remoteRelay { _ = relay.dispatch(.pause) }
                else { self.pause() }
            }
            return .success
        }

        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let relay = self.remoteRelay { _ = relay.dispatch(.toggle) }
                else { self.togglePlayback() }
            }
            return .success
        }

        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let relay = self?.remoteRelay else { return }
                _ = relay.dispatch(.next)
            }
            return .success
        }

        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let relay = self?.remoteRelay else { return }
                _ = relay.dispatch(.previous)
            }
            return .success
        }

        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite, event.positionTime >= 0 else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                guard let relay = self?.remoteRelay else { return }
                _ = relay.dispatch(.seek(position))
            }
            return .success
        }

        [commands.skipForwardCommand, commands.skipBackwardCommand,
         commands.changePlaybackRateCommand].forEach { $0.isEnabled = false }
        updateRemoteCommandAvailability()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("AudioEngineManager: falha ao configurar AVAudioSession – \(error)")
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let systemAllows = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    let wasPlaying = self.isPlaying
                    let source = self.sourceURL
                    self.pause()
                    // Pause invalidates any previous request. Capture *after*
                    // it so a later user pause or replacement cancels resumption.
                    self.interruptedSourceURL = wasPlaying ? source : nil
                case .ended:
                    let priorSource = self.interruptedSourceURL
                    self.interruptedSourceURL = nil
                    let shouldResume = AudioInterruptionResumePolicy.shouldResume(
                        wasPlaying: priorSource != nil,
                        systemAllows: systemAllows,
                        sameSource: self.sourceURL == priorSource,
                        userOverrode: false)
                    if shouldResume && !self.isPlaying {
                        do {
                            try AVAudioSession.sharedInstance().setActive(true)
                            self.play()
                        } catch {
                            // Remain paused when reactivation fails.
                            self.setupNowPlaying()
                        }
                    }
                @unknown default: break
                }
            }
        }

        // A disconnected output pauses without auto-switching to speaker.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let removed = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ==
                .oldDeviceUnavailable
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lyricsClock.refreshOutputLatency()
                self.refreshPerformanceOutputLatency()
                if removed {
                    self.interruptedSourceURL = nil
                    self.pause()
                }
            }
        }
    }

    // MARK: - Limpeza de cache

    /// Only clean temporary files and import directories OWNED by NightcoreLab.
    /// The shared application temp directory can contain inputs for tests,
    /// share extensions and other features: deleting every audio file here
    /// would destroy a source immediately before load(url:).
    private func clearTempAudioFiles() {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory

        guard let files = try? fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var freedBytes: Int64 = 0
        for url in files {
            if url.lastPathComponent.hasPrefix("nightcore_import_"),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fileManager.removeItem(at: url)
                continue
            }
            // Old audio exports had arbitrary source-name prefixes. They cannot
            // safely be distinguished from user files, so intentionally keep
            // them rather than deleting someone else's temporary WAV.
            let owned = url.lastPathComponent.hasPrefix("nightcore_export_") ||
                        url.lastPathComponent.hasPrefix("NightcorePerformance-")
            guard owned,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .audio) else { continue }

            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if (try? fileManager.removeItem(at: url)) != nil {
                freedBytes += size
            }
        }

        #if DEBUG
        if freedBytes > 0 {
            print("AudioEngineManager: cache limpo, \(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)) liberados")
        }
        #endif
    }

    // MARK: - Privado: grafo e render offline (sem isolamento de ator)

    nonisolated private static func connectGraph(engine: AVAudioEngine,
                                                 player: AVAudioPlayerNode,
                                                 upmix: AVAudioMixerNode,
                                                 varispeed: AVAudioUnitVarispeed,
                                                 timePitch: AVAudioUnitTimePitch,
                                                 eq: AVAudioUnitEQ,
                                                 reverb: AVAudioUnitReverb,
                                                 limiter: AVAudioUnitEffect,
                                                 fileFormat: AVAudioFormat,
                                                 graphFormat: AVAudioFormat,
                                                 performanceMixer: AVAudioMixerNode? = nil) {
        // O mixer converte mono→estéreo e taxa de amostragem, deixando o resto do grafo uniforme.
        engine.connect(player, to: upmix, format: fileFormat)
        engine.connect(upmix, to: varispeed, format: graphFormat)
        engine.connect(varispeed, to: timePitch, format: graphFormat)
        engine.connect(timePitch, to: eq, format: graphFormat)
        engine.connect(eq, to: reverb, format: graphFormat)
        // Pad samples join after the song-specific DSP so a 0.5x playback
        // speed does not slow the live drums. Both inputs share the limiter.
        if let performanceMixer {
            engine.connect(reverb, to: performanceMixer, format: graphFormat)
            engine.connect(performanceMixer, to: limiter, format: graphFormat)
        } else {
            engine.connect(reverb, to: limiter, format: graphFormat)
        }
        engine.connect(limiter, to: engine.mainMixerNode, format: graphFormat)
        engine.mainMixerNode.outputVolume = pow(10, outputHeadroomDB / 20)
    }

    nonisolated static func playbackRates(speed: Float, pitch: Float) -> (tape: Float, stretch: Float) {
        let tape = pow(2, pitch / 1200)
        return (tape, speed / tape)
    }

    nonisolated private static func configurePlayback(varispeed: AVAudioUnitVarispeed,
                                                       timePitch: AVAudioUnitTimePitch,
                                                       speed: Float, pitch: Float) {
        let rates = playbackRates(speed: speed, pitch: pitch)
        varispeed.rate = rates.tape
        timePitch.pitch = 0
        timePitch.rate = rates.stretch
        // No efeito de fita, não submete transientes e agudos ao algoritmo de time-stretch.
        timePitch.bypass = abs(rates.stretch - 1) < 0.0001
    }

    // MARK: - Fábricas dos nós (usadas pela engine ao vivo e pela offline,
    // garantindo que o export soe idêntico ao preview)

    nonisolated private static func makeTimePitch() -> AVAudioUnitTimePitch {
        let node = AVAudioUnitTimePitch()
        node.overlap = timePitchOverlap
        return node
    }

    nonisolated private static func makeBassEQ() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.globalGain = 0
        let band = eq.bands[0]
        band.filterType = .lowShelf
        band.frequency = bassFrequency
        band.bandwidth = bassBandwidth
        band.gain = 0
        band.bypass = false
        return eq
    }

    nonisolated private static func makeReverb() -> AVAudioUnitReverb {
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(defaultReverbPreset)   // preset antes de qualquer wetDryMix
        reverb.wetDryMix = 0
        reverb.bypass = true
        return reverb
    }

    /// Peak limiter dedicado. A margem final é aplicada no mixer após a limitação.
    nonisolated private static func makeLimiter() -> AVAudioUnitEffect {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let limiter = AVAudioUnitEffect(audioComponentDescription: description)
        let unit = limiter.audioUnit

        // Genérico: conforme o SDK, as constantes chegam como Int ou AudioUnitParameterID.
        func set<P: BinaryInteger>(_ parameter: P, _ value: AudioUnitParameterValue) {
            AudioUnitSetParameter(unit, AudioUnitParameterID(parameter), kAudioUnitScope_Global, 0, value, 0)
        }
        set(kLimiterParam_AttackTime, limiterAttack)
        set(kLimiterParam_DecayTime, limiterRelease)
        set(kLimiterParam_PreGain, 0)
        return limiter
    }

    nonisolated static func renderOffline(source: URL,
                                                  settings: RenderSettings,
                                                  format: ExportFormat,
                                                  progress: @Sendable (Double) -> Void,
                                                  startTime: TimeInterval = 0,
                                                  maxDuration: TimeInterval? = nil,
                                                  performance: PerformanceTimeline? = nil) throws -> URL {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceRate = file.processingFormat.sampleRate
        guard file.length > 0, sourceRate > 0, (1...2).contains(file.processingFormat.channelCount),
              speedRange.contains(settings.speed), pitchRange.contains(settings.pitch),
              reverbRange.contains(settings.reverb), bassRange.contains(settings.bass) else {
            throw AudioEngineError.unsupportedAudio
        }
        // AAC em taxas convencionais; WAV mantém a taxa original.
        let outputRate = format == .m4a ? (sourceRate == 44_100 ? 44_100.0 : 48_000.0) : sourceRate
        let sourceSeconds = Double(file.length) / sourceRate
        let tailSeconds = maxDuration == nil ? (settings.reverb > 0 ? 3.0 : 0.1) : 0.0
        let available = max(0, sourceSeconds - min(max(startTime, 0), sourceSeconds))
                        / Double(settings.speed)
        let selectedSeconds = min(maxDuration ?? available, available)
        guard selectedSeconds > 0 else { throw AudioEngineError.unsupportedAudio }
        // Pad stem is generated ONLY during requested export (chunked file IO).
        // It enters the same limiter as the song, before final PCM/AAC encoding.
        let padStemURL = try performance.map {
            try PerformancePadMixdown.write($0, startTime: startTime,
                                            speed: settings.speed,
                                            duration: selectedSeconds + tailSeconds,
                                            sampleRate: outputRate, sourceURL: source)
        }
        defer {
            if let padStemURL { try? FileManager.default.removeItem(at: padStemURL) }
        }

        // Engine separada: o export não interrompe o playback.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let upmix = AVAudioMixerNode()
        let varispeed = AVAudioUnitVarispeed()
        let timePitch = makeTimePitch()
        let eq = makeBassEQ()
        let reverb = makeReverb()
        let limiter = makeLimiter()
        [player, upmix, varispeed, timePitch, eq, reverb, limiter].forEach { engine.attach($0) }
        let performanceMixer = padStemURL.map { _ in AVAudioMixerNode() }
        let padPlayer = padStemURL.map { _ in AVAudioPlayerNode() }
        if let performanceMixer, let padPlayer {
            engine.attach(performanceMixer)
            engine.attach(padPlayer)
        }
        let padFile = try padStemURL.map {
            try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32,
                            interleaved: false)
        }

        configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: settings.speed, pitch: settings.pitch)
        eq.bands[0].gain = settings.bass
        eq.globalGain = -settings.bass
        reverb.loadFactoryPreset(AVAudioUnitReverbPreset(rawValue: settings.reverbPresetRaw) ?? defaultReverbPreset)
        reverb.wetDryMix = settings.reverb
        reverb.bypass = settings.reverb == 0

        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        connectGraph(engine: engine, player: player, upmix: upmix, varispeed: varispeed, timePitch: timePitch, eq: eq,
                     reverb: reverb, limiter: limiter,
                     fileFormat: file.processingFormat, graphFormat: renderFormat,
                     performanceMixer: performanceMixer)
        if let padPlayer, let performanceMixer {
            engine.connect(padPlayer, to: performanceMixer, format: renderFormat)
        }

        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()
        if let maxDuration {
            let startFrame = AVAudioFramePosition(min(max(startTime, 0) * sourceRate,
                                                      Double(file.length)))
            let frames = min(file.length - startFrame,
                             AVAudioFramePosition(maxDuration * Double(settings.speed) * sourceRate))
            guard frames > 0 else { throw AudioEngineError.unsupportedAudio }
            player.scheduleSegment(file, startingFrame: startFrame,
                                   frameCount: AVAudioFrameCount(min(frames, Int64(UInt32.max))),
                                   at: nil)
        } else {
            player.scheduleFile(file, at: nil)
        }
        player.play()
        if let padPlayer, let padFile {
            padPlayer.scheduleFile(padFile, at: nil)
            padPlayer.play()
        }
        defer {
            padPlayer?.stop()
            player.stop()
            engine.stop()
        }

        // Duração final = duração original / speed + cauda do reverb.
        let totalFrames = AVAudioFramePosition((selectedSeconds + tailSeconds) * outputRate)

        // Arquivo de saída
        let baseName = source.deletingPathExtension().lastPathComponent
        let tag = settings.speed >= 1 ? "nightcore" : "slowed"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nightcore_export_\(baseName)_\(tag)_\(UUID().uuidString.prefix(8)).\(format.rawValue)")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: outputURL) } }

        let fileSettings: [String: Any]
        switch format {
        case .m4a:
            fileSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: outputRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 320_000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
                AVSampleRateConverterAudioQualityKey: AVAudioQuality.max.rawValue
            ]
        case .wav:
            fileSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: outputRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: fileSettings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw AudioEngineError.bufferAllocationFailed
        }

        var rendered: AVAudioFramePosition = 0
        var lastReported = 0.0
        var stalledRenders = 0

        while rendered < totalFrames {
            try Task.checkCancellation()
            let remaining = totalFrames - rendered
            let framesToRender = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))

            switch try engine.renderOffline(framesToRender, to: buffer) {
            case .success, .insufficientDataFromInputNode:
                guard buffer.frameLength > 0 else {
                    stalledRenders += 1
                    if stalledRenders > 1000 { throw AudioEngineError.renderFailed }
                    continue
                }
                stalledRenders = 0
                try outputFile.write(from: buffer)
                rendered += AVAudioFramePosition(buffer.frameLength)

                let fraction = Double(rendered) / Double(totalFrames)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            case .cannotDoInCurrentContext:
                stalledRenders += 1
                if stalledRenders > 1000 { throw AudioEngineError.renderFailed }
                continue
            case .error:
                throw AudioEngineError.renderFailed
            @unknown default:
                throw AudioEngineError.renderFailed
            }
        }

        completed = true
        return outputURL
        // outputFile é fechado ao sair do escopo, antes da URL ser usada.
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

