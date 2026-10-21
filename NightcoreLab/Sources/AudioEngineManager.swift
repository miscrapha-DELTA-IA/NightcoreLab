import AVFoundation
import Darwin
import AudioToolbox
import MediaPlayer
import Observation
import UniformTypeIdentifiers
import OSLog
import UIKit

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
    case stemPreparationInProgress

    var errorDescription: String? {
        switch self {
        case .noFileLoaded:            return "Nenhuma música carregada."
        case .bufferAllocationFailed:  return "Não foi possível alocar o buffer de áudio."
        case .renderFailed:            return "Falha ao renderizar o áudio."
        case .unsupportedAudio:        return "Áudio inválido ou não suportado. Importe MP3, M4A, WAV ou AIFF."
        case .exportInProgress:        return "Aguarde a exportação atual terminar."
        case .stemPreparationInProgress: return "Aguarde a separação terminar ou cancele antes de exportar."
        }
    }
}

private enum KaraokeInputError: LocalizedError {
    case unavailable
    case invalidHardwareFormat
    case engineStopped

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Nenhuma entrada de microfone está disponível nesta rota de áudio."
        case .invalidHardwareFormat: return "O iPhone não forneceu um formato de captura válido para o microfone."
        case .engineStopped: return "O motor de áudio parou ao ativar o microfone."
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
    let stemLevels: [StemKind: Float]?
    let stemAsset: StemAsset?
    init(url: URL, settings: RenderSettings, stemLevels: [StemKind: Float]?, stemAsset: StemAsset? = nil) {
        self.url = url; self.settings = settings; self.stemLevels = stemLevels; self.stemAsset = stemAsset
    }
}

// MARK: - AudioEngineManager

@MainActor
@Observable
final class AudioEngineManager {
    typealias NeuralPreparation = @Sendable (
        URL, NeuralStemRequest, @escaping @Sendable () -> Void,
        @escaping @Sendable (Double, String) -> Void
    ) async throws -> StemAsset

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
    private(set) var isExporting = false {
        didSet { updateRemoteCommandAvailability() }
    }
    private(set) var exportProgress: Double = 0

    private(set) var speed: Float = 1.0
    private(set) var pitch: Float = 0
    private(set) var reverb: Float = 0
    private(set) var bass: Float = 0

    // Grafo de áudio (masterização):
    // player → upmix → varispeed → timePitch (só quando necessário) → EQ → reverb → limiter → saída
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let centerCutPlayer = AVAudioPlayerNode()
    private let originalUpmix = AVAudioMixerNode()
    /// In-process render effect; the original player remains the transport.
    private let stemMaskNode = StemGainAudioUnit.makeNode(initialGain: 1)
    @ObservationIgnored private let neuralStems = NeuralStemPlayback()
    @ObservationIgnored private var stemPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var stemPreparationID = UUID()
    @ObservationIgnored private let neuralPreparation: NeuralPreparation
    @ObservationIgnored private var preparedStemAssets: [URL: StemAsset] = [:]
    @ObservationIgnored private var stemBackgroundLease: UIBackgroundTaskIdentifier = .invalid
    private(set) var stemPreparationTitle = ""
    private(set) var stemPreparationIsCloud = false
    private(set) var canResumeStemPreparation = false
    private(set) var isPreparingStems = false
    private(set) var isCancellingStems = false
    private(set) var stemPreparationProgress = 0.0
    private(set) var stemPreparationMessage = ""
    private(set) var stemPreparationError: String?
    private(set) var stemPreview: StemAsset?
    var hasNeuralStemModel: Bool {
        if #available(iOS 18, *) { return NeuralStemWorker.bundledModel != nil }
        return false
    }
    var hasStemSource: Bool { sourceURL != nil }
    private(set) var stemMixEnabled = false
    private(set) var stemLevels: [StemKind: Float] = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0, 1) })
    private(set) var stemsAvailable = false
    private(set) var stemSource: StemSource?
    static let stemRange: ClosedRange<Float> = 0...2
    nonisolated static func stemGainDB(for level: Float) -> Float {
        let v = min(2, max(0, level))
        return v <= 1 ? (v - 1) * 18 : (v - 1) * 9
    }
    func liveStemEQGain(_ kind: StemKind) -> Float { 0 } // legacy test API
    private(set) var centerCutEnabled = false
    private(set) var centerCutAvailable = true
    @ObservationIgnored private var centerCutFile: AVAudioFile?
    @ObservationIgnored private var centerCutURL: URL?
    @ObservationIgnored private var centerCutPrepareTask: Task<Void, Never>?
    @ObservationIgnored private var centerCutRampTask: Task<Void, Never>?
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
    /// Shared with the Creator/Performance sheet and the Story snapshot.
    @ObservationIgnored let performanceRecorder = PerformanceRecorder()
    @ObservationIgnored let padAccentEmitter = PadVisualAccentEmitter()
    @ObservationIgnored private(set) var performanceRecordingSourceRevision: Int?
    @ObservationIgnored var padQuantizeStrength: Float = 0
    /// Read by the visible Player at visual FPS; published nowhere on the
    /// render/audio thread. Uses the existing main mixer output, not a second graph.
    @ObservationIgnored let liveVisualMeter = AudioVisualLiveMeter()
    @ObservationIgnored private var liveMeterTapInstalled = false

    /// The *same* live AVAudioEngine houses all four loop voices and native
    /// vocal units. Mic monitoring is gated after processing, before limiter.
    @ObservationIgnored let creatorLoops = CreatorLoopEngine()
    private(set) var activeCreatorLoops: Set<CreatorLoopSlot> = []
    private(set) var vocalCaptureActive = false
    private(set) var vocalMonitoringEnabled = false
    private(set) var vocalSetting = VocalFXSetting()
    @ObservationIgnored private let vocalInputAdapter = AVAudioMixerNode()
    @ObservationIgnored private let vocalPitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let vocalEQ = AVAudioUnitEQ(numberOfBands: 2)
    @ObservationIgnored private let vocalDelay = AVAudioUnitDelay()
    @ObservationIgnored private let vocalReverb = AVAudioUnitReverb()
    @ObservationIgnored private let vocalGate = AVAudioMixerNode()
    @ObservationIgnored private var microphoneCapture: KaraokeMicrophoneCapture?
    private(set) var karaokeCaptureActive = false
    private(set) var karaokeMicrophoneFailure: String?
    @ObservationIgnored private var karaokeCapture: KaraokeMicrophoneCapture?
    @ObservationIgnored private var karaokeInput: AVAudioInputNode?
    @ObservationIgnored private var karaokeGeneration = 0
    /// Never read engine.inputNode just to initialize the engine or clean up
    /// headless CI; retained only after a hardware-format validation.
    @ObservationIgnored private var connectedVocalInput: AVAudioInputNode?
    @ObservationIgnored private var vocalGeneration = 0
    @ObservationIgnored var karaokeCompletion: (() -> Void)?

    var performanceKit: PadKit { padRuntime.kit }
    var performanceSourceClip: PerformanceSourceClip? { padRuntime.sourceClip }
    var performancePadsReady: Bool { padRuntime.isReady }

    /// Ordem da cadeia, usada para attach e para desconectar ao trocar de música.
    private var processingNodes: [AVAudioNode] {
        let sources: [AVAudioNode] = [player, centerCutPlayer] + neuralStems.nodes
        return sources +
            [originalUpmix, upmix, varispeed, timePitch, bassEQ, stemMaskNode,
             reverbNode, performanceMixer, limiter]
    }

    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkLoadTask: Task<Void, Never>?
    /// Read-only source for offline visual evidence. Live RMS/bass are
    /// independently obtained from the existing mixer through liveVisualMeter.
    var visualAnalysisURL: URL? { sourceURL }
    @ObservationIgnored private var needsScheduling = true
    @ObservationIgnored private(set) var scheduleGeneration = 0
    private(set) var isReconfiguringGraph = false
    var microphonePermissionDenied: Bool {
        Self.shouldShowMicrophonePermissionError(AVAudioApplication.shared.recordPermission)
    }
    nonisolated static func shouldShowMicrophonePermissionError(
        _ permission: AVAudioApplication.recordPermission) -> Bool { permission == .denied }
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

    init(idleStopDelay: Duration = .seconds(10),
         neuralPreparation: @escaping NeuralPreparation = { source, request, reclaim, progress in
             try await NeuralStemWorker.prepare(source: source, request: request, reclaimMemory: reclaim, progress: progress)
         }) {
        self.idleStopDelay = max(.zero, idleStopDelay)
        self.neuralPreparation = neuralPreparation
        Task.detached(priority: .utility) { Self.clearTempAudioFiles() }
        configureSession()
        setupEngine()
        observeInterruptions()
        setupRemoteTransportControls()
    }

    /// Anexa a cadeia de masterização e aplica os valores iniciais dos controles.
    /// As conexões são feitas em `load(url:)`, quando o formato do arquivo é conhecido.
    private func setupEngine() {
        processingNodes.forEach { engine.attach($0) }
        // Microphone DSP units are attached only after permission and a
        // valid hardware input format. The simulator needs no input graph.
        padRuntime.attach(to: engine)
        // Pads can sound before a song has been selected.
        let standaloneFormat = AVAudioFormat(
            standardFormatWithSampleRate: PadSampleSynthesizer.sampleRate, channels: 2)!
        engine.connect(performanceMixer, to: limiter, format: standaloneFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: standaloneFormat)
        padRuntime.connect(to: engine, mixer: performanceMixer)
        creatorLoops.attach(to: engine, output: performanceMixer,
                            format: standaloneFormat)
        engine.mainMixerNode.outputVolume = pow(10, Self.outputHeadroomDB / 20)
        engine.prepare()

        Self.configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: speed, pitch: pitch)
        bassEQ.bands[0].gain = bass
        reverbNode.wetDryMix = reverb
    }

    // MARK: Carregar arquivo

    func load(url: URL, preparedFile: AVAudioFile? = nil) throws {
        // The separation owns its source copy. A queue change only replaces
        // playback; it must neither cancel the job nor attach the wrong stems.
        stemPreview = nil
        neuralStems.clear()
        stemMixEnabled = false
        stemsAvailable = false
        stemSource = nil
        stemLevels = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, 1) })
        centerCutPrepareTask?.cancel()
        centerCutRampTask?.cancel()
        centerCutPlayer.stop()
        centerCutFile = nil
        if let centerCutURL { AudioFilePreparation.remove(centerCutURL) }
        centerCutURL = nil
        centerCutEnabled = false
        interruptedSourceURL = nil // A replacement must never resume a prior source.
        // Core Audio decodifica MP3/AAC para PCM float; não há conversão com perdas na importação.
        let file = try preparedFile ?? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              (1...2).contains(file.processingFormat.channelCount) else {
            throw AudioEngineError.unsupportedAudio
        }
        endKaraokeMicrophone()
        endVocalCapture()
        stopAllCreatorLoops()
        stopPlayback()
        audioFile = file
        centerCutAvailable = file.processingFormat.channelCount == 2
        sourceURL = url
        playbackSourceRevision &+= 1
        artworkLoadTask?.cancel()
        nowPlayingArtwork = NowPlayingArtworkLoader.officialLogo()
        performanceRecorder.clearAll()
        performanceRecordingSourceRevision = nil
        padAccentEmitter.clear()
        fileName = url.deletingPathExtension().lastPathComponent
        duration = Double(file.length) / file.processingFormat.sampleRate

        removeVisualMeterTap()
        engine.stop()
        neuralStems.detach(from: engine)
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
                          performanceMixer: performanceMixer,
                          originalGain: (originalUpmix, stemMaskNode))
        engine.connect(centerCutPlayer, to: upmix, format: graphFormat)
        centerCutPlayer.volume = 0
        stemsAvailable = false
        stemSource = nil
        player.volume = 1
        padRuntime.connect(to: engine, mixer: performanceMixer)
        // No mic FX wiring during load/prepare/offline tests. It is done on
        // opt-in activation, after validating actual hardware input.
        creatorLoops.attach(to: engine, output: performanceMixer, format: graphFormat)
        engine.prepare()
        sendStemParameters()
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
        if let asset = preparedStemAssets[url], asset.preview == nil {
            try installPreparedStems(asset)
        }
        // Deferred to Stems tab: normal playback and karaoke do not run separation.
    }

    /// One tap, no transport mutation and no AVAudioSession query.
    func beginPadTake(overdub: Bool = false) {
        if !overdub || performanceRecorder.events.isEmpty {
            performanceRecordingSourceRevision = playbackSourceRevision
            performanceRecorder.start()
        } else if performanceRecordingSourceRevision == playbackSourceRevision {
            performanceRecorder.overdub()
        }
    }

    func stopPadTake() { performanceRecorder.stop() }
    func clearLastPadTake() { performanceRecorder.clearLastTake() }

    /// Frozen, source-identity-matched snapshot for Story preview/export.
    func frozenPadPerformance(quantizeStrength: Float? = nil) -> PerformanceTimeline? {
        guard !performanceRecorder.isRecording,
              performanceRecordingSourceRevision == playbackSourceRevision,
              !performanceRecorder.events.isEmpty else { return nil }
        let result = performanceRecorder.timeline(
            sourceClip: padRuntime.sourceClip,
            quantizeStrength: quantizeStrength ?? padQuantizeStrength)
        return result.isValid ? result : nil
    }

    // MARK: Mic and Creator loops (one pre-existing audio graph)

    func applyVocalFX(_ settings: VocalFXSetting) {
        guard settings.isValid else { return }
        vocalSetting = settings
        guard vocalPitch.engine != nil else { return }
        let m = VocalFXParameters.resolve(settings)
        vocalPitch.rate = 1
        vocalPitch.pitch = m.pitchCents
        vocalEQ.bands[0].filterType = .parametric
        vocalEQ.bands[0].frequency = 3300
        vocalEQ.bands[0].bandwidth = 1.2
        vocalEQ.bands[0].gain = m.eqPresenceDB
        vocalEQ.bands[0].bypass = false
        vocalEQ.bands[1].filterType = .lowPass
        vocalEQ.bands[1].frequency = m.lowPassHz
        vocalEQ.bands[1].bypass = m.lowPassHz >= 17_999
        vocalDelay.delayTime = m.delaySeconds
        vocalDelay.feedback = 4
        vocalDelay.wetDryMix = m.delayWetMix
        vocalReverb.loadFactoryPreset(m.reverbPreset)
        vocalReverb.wetDryMix = m.reverbWetMix
        refreshVocalMonitorSafety()
    }

    /// The adapter mixer owns sample-rate/channel conversion. Never force the
    /// song format onto the hardware input bus (e.g. 48k mono -> 44.1k stereo).
    private func connectVocalChain(input: AVAudioInputNode, format: AVAudioFormat) {
        if vocalPitch.engine == nil {
            [vocalInputAdapter, vocalPitch, vocalEQ, vocalDelay, vocalReverb, vocalGate]
                .forEach { engine.attach($0) }
        }
        vocalGate.outputVolume = 0
        let songFormat = performanceMixer.outputFormat(forBus: 0)
        engine.connect(input, to: vocalInputAdapter, format: format)
        engine.connect(vocalInputAdapter, to: vocalPitch, format: songFormat)
        engine.connect(vocalPitch, to: vocalEQ, format: songFormat)
        engine.connect(vocalEQ, to: vocalDelay, format: songFormat)
        engine.connect(vocalDelay, to: vocalReverb, format: songFormat)
        engine.connect(vocalReverb, to: vocalGate, format: songFormat)
        engine.connect(vocalGate, to: performanceMixer, format: songFormat)
    }

    private func refreshVocalMonitorSafety() {
        let session = AVAudioSession.sharedInstance()
        let safe = vocalCaptureActive && VocalMonitorSafety.allows(
            session.currentRoute.outputs, latency: session.outputLatency)
        vocalMonitoringEnabled = safe
        vocalGate.outputVolume = safe ? min(0.5, vocalSetting.intensity * 0.42) : 0
    }

    /// Explicit opt-in only. Opening lyrics never calls this method.
    func beginVocalCapture() async -> Bool {
        if vocalCaptureActive { return true }
        endKaraokeMicrophone()
        vocalGeneration &+= 1
        let requested = vocalGeneration
        let permission = AVAudioApplication.shared.recordPermission
        let allowed = permission == .granted ? true :
            (permission == .undetermined ? await AVAudioApplication.requestRecordPermission() : false)
        guard allowed, requested == vocalGeneration, !Task.isCancelled else { return false }
        let resume = isPlaying
        beginGraphReconfiguration()
        defer { finishGraphReconfiguration(resume: resume) }
        let capture = KaraokeMicrophoneCapture()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            // Inspect input only AFTER activating the recording session.
            guard session.isInputAvailable else { throw AudioEngineError.unsupportedAudio }
            let input = engine.inputNode
            let native = input.outputFormat(forBus: 0)
            guard native.channelCount > 0, native.sampleRate.isFinite,
                  native.sampleRate > 0 else { throw AudioEngineError.unsupportedAudio }
            let scoringClock = lyricsClock
            // Analysis reads native PCM; the separate adapter converts monitor audio.
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                capture.capture(buffer, sourceTime: scoringClock.lyricTime)
            }
            connectedVocalInput = input
            connectVocalChain(input: input, format: native)
            microphoneCapture = capture
            vocalCaptureActive = true
            applyVocalFX(vocalSetting)
            try engine.start()
            installVisualMeterTap()
            return true
        } catch {
            if let input = connectedVocalInput {
                input.removeTap(onBus: 0)
                engine.disconnectNodeOutput(input)
            }
            connectedVocalInput = nil
            capture.stop()
            microphoneCapture = nil
            vocalCaptureActive = false
            refreshVocalMonitorSafety()
            configureSession()
            return false // Busy hardware keeps passive scoring; not a permission error.
        }
    }

    /// Invalidate BEFORE stop: callbacks already enqueued remain stale after
    /// the guard is lowered. A Boolean alone cannot protect delayed callbacks.
    func beginGraphReconfiguration() {
        let position = min(duration, max(0, lyricsClock.lyricTime))
        isReconfiguringGraph = true
        scheduleGeneration &+= 1
        cancelIdleStop()
        lastKnownTime = position
        lyricsClock.didPause(at: position)
        isPlaying = false
        player.stop()
        neuralStems.stop()
        needsScheduling = true
        scheduledStartTime = position
        removeVisualMeterTap()
        engine.stop()
    }

    func finishGraphReconfiguration(resume: Bool) {
        isReconfiguringGraph = false
        lyricsClock.refreshOutputLatency()
        if resume { play() }
        else if performanceModePresented { try? engine.start() }
        else { scheduleIdleStop() }
    }

    /// Scoring only: rebuild the existing engine with its hardware input tap,
    /// then resume the same song position. Creating inputNode on a running
    /// playback-only graph can stop its I/O unit without starting the tap.
    var karaokeMicrophoneActive: Bool { karaokeCaptureActive || vocalCaptureActive }
    func beginKaraokeMicrophone() async -> Bool {
        if karaokeMicrophoneActive { return true }
        karaokeMicrophoneFailure = nil
        karaokeGeneration &+= 1
        let requested = karaokeGeneration
        let sourceRevision = playbackSourceRevision
        let permission = AVAudioApplication.shared.recordPermission
        let allowed = permission == .granted ? true :
            (permission == .undetermined ? await AVAudioApplication.requestRecordPermission() : false)
        guard allowed, requested == karaokeGeneration,
              sourceRevision == playbackSourceRevision, !Task.isCancelled else { return false }
        let resume = isPlaying
        beginGraphReconfiguration()
        defer { finishGraphReconfiguration(resume: resume) }
        let session = AVAudioSession.sharedInstance()
        let capture = KaraokeMicrophoneCapture()
        var tappedInput: AVAudioInputNode?
        do {
            // Mic permission is independent of SFSpeechRecognizer. A denied
            // message is NEVER derived from route/format/session exceptions.
            if session.category != .playAndRecord {
                try session.setCategory(.playAndRecord, mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
            try session.setActive(true)
            guard session.isInputAvailable else { throw KaraokeInputError.unavailable }
            let input = engine.inputNode
            let hardware = input.inputFormat(forBus: 0)
            let native = input.outputFormat(forBus: 0)
            guard hardware.sampleRate.isFinite, hardware.sampleRate > 0,
                  hardware.channelCount > 0, native.sampleRate.isFinite,
                  native.sampleRate > 0, native.channelCount > 0 else {
                throw KaraokeInputError.invalidHardwareFormat
            }
            if let previous = karaokeInput { previous.removeTap(onBus: 0) }
            let scoringClock = lyricsClock
            // The tap observes the input node's output format. Supplying its
            // input-bus format can reformat an already connected output bus.
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                capture.capture(buffer, sourceTime: scoringClock.lyricTime)
            }
            tappedInput = input
            guard requested == karaokeGeneration, !Task.isCancelled else {
                input.removeTap(onBus: 0); capture.stop(); return false
            }
            cancelIdleStop()
            try engine.start()
            guard engine.isRunning else { throw KaraokeInputError.engineStopped }
            karaokeInput = input
            karaokeCapture = capture
            karaokeCaptureActive = true
            return true
        } catch {
            tappedInput?.removeTap(onBus: 0)
            capture.stop()
            karaokeMicrophoneFailure = error.localizedDescription
            // An audio route or format failure must not report permissionDenied.
            NSLog("Karaoke microphone hardware initialization failed: %@", error.localizedDescription)
            return false
        }
    }

    private func restorePlaybackAfterKaraokeInputChange(
        wasPlaying: Bool, at position: TimeInterval, sourceRevision: Int
    ) {
        guard wasPlaying, sourceRevision == playbackSourceRevision,
              !engine.isRunning || !player.isPlaying || !isPlaying else { return }
        lastKnownTime = position
        isPlaying = true // seek preserves and resumes the pre-activation transport state.
        seek(to: position)
    }

    func endKaraokeMicrophone() {
        karaokeGeneration &+= 1
        let wasPlaying = isPlaying
        let position = currentTime
        let sourceRevision = playbackSourceRevision
        let wasReconfiguringGraph = isReconfiguringGraph
        isReconfiguringGraph = true
        if let input = karaokeInput { input.removeTap(onBus: 0) }
        karaokeInput = nil
        karaokeCapture?.stop()
        karaokeCapture = nil
        karaokeCaptureActive = false
        restorePlaybackAfterKaraokeInputChange(wasPlaying: wasPlaying,
            at: position, sourceRevision: sourceRevision)
        isReconfiguringGraph = wasReconfiguringGraph
        if !wasPlaying && !wasReconfiguringGraph { scheduleIdleStop() }
    }

    func karaokeVoiceFrame() -> KaraokeVoiceFrame {
        (karaokeCapture ?? microphoneCapture)?.frame(at: lyricsClock.lyricTime) ?? .silence
    }

    func endVocalCapture() {
        vocalGeneration &+= 1
        karaokeCompletion = nil
        guard vocalCaptureActive || microphoneCapture != nil ||
              connectedVocalInput != nil else { return }
        let resume = isPlaying
        beginGraphReconfiguration()
        defer { finishGraphReconfiguration(resume: resume) }
        if let input = connectedVocalInput {
            input.removeTap(onBus: 0)
            engine.disconnectNodeOutput(input)
            connectedVocalInput = nil
        }
        microphoneCapture?.stop()
        microphoneCapture = nil
        vocalCaptureActive = false
        vocalGate.outputVolume = 0
        vocalMonitoringEnabled = false
        configureSession()
    }

    func toggleCreatorLoop(_ slot: CreatorLoopSlot, rhythm: RhythmAnalysisResult?,
                           key: KeyAnalysisResult?) -> Bool {
        let launched = creatorLoops.toggle(
            slot, sourceTime: currentTime, speed: speed,
            rhythm: rhythm, key: key, engine: engine,
            onStopped: { [weak self] slot in
                _ = self?.activeCreatorLoops.remove(slot)
            })
        if launched { activeCreatorLoops = creatorLoops.active }
        return launched
    }

    func stopAllCreatorLoops() {
        creatorLoops.stopAll()
        activeCreatorLoops = []
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
            min(0.200, max(0, latency)) : 0
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
        if played {
            // AFTER the audio command; the shader samples this lock-free of
            // any SwiftUI invalidation via its own TimelineView.
            padAccentEmitter.trigger(padID, velocity: velocity)
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
            installVisualMeterTap()
            if performanceModePresented { padRuntime.primeVoices() }
            if needsScheduling {
                // Preserve the existing replay-from-start behavior at EOF.
                if lastKnownTime >= duration { lastKnownTime = 0 }
                schedule(file, startingAt: lastKnownTime)
                if centerCutEnabled { scheduleCenterCut(startingAt: lastKnownTime) }
            }
            lyricsClock.refreshOutputLatency()
            let anchor = neuralStems.asset == nil ? nil :
                AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.03))
            player.play(at: anchor)
            neuralStems.play(at: anchor)
            if centerCutEnabled, centerCutFile != nil { centerCutPlayer.play(at: anchor) }
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
        neuralStems.pause()
        centerCutPlayer.pause()
        if neuralStems.asset != nil {
            // Re-anchor every source on resume rather than accumulating up to
            // one render quantum of skew between sequential pause calls.
            scheduleGeneration += 1
            player.stop(); neuralStems.stop(); centerCutPlayer.stop()
            scheduledStartTime = lastKnownTime; needsScheduling = true
        }
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
        guard !performanceModePresented, !vocalCaptureActive,
              !karaokeCaptureActive else { return }
        let generation = idleStopGeneration
        let deadline = ContinuousClock.now.advanced(by: idleStopDelay)
        idleStopTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self,
                  generation == self.idleStopGeneration,
                  !self.isPlaying, !self.performanceModePresented,
                  !self.vocalCaptureActive, !self.karaokeCaptureActive else { return }
            // Capture happened at pause/seek, before invalidating node time.
            self.scheduleGeneration += 1
            self.player.stop()
            self.neuralStems.stop()
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
        neuralStems.stop()
        centerCutPlayer.stop()
        isPlaying = false
        lastKnownTime = target
        lyricsClock.didSeek(to: target)
        scheduledStartTime = target
        needsScheduling = true
        if target < duration {
            schedule(file, startingAt: target)
            if centerCutEnabled { scheduleCenterCut(startingAt: target) }
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

    func setCenterCutEnabled(_ enabled: Bool) {
        if enabled && stemMixEnabled { setStemMixerEnabled(false) }
        centerCutEnabled = enabled
        centerCutRampTask?.cancel()
        guard enabled else { crossfadeCenterCut(to: false); return }
        guard let sourceURL, let file = audioFile,
              file.processingFormat.channelCount == 2 else {
            centerCutAvailable = false
            centerCutEnabled = false
            return
        }
        centerCutAvailable = true
        if centerCutFile != nil {
            scheduleCenterCut(startingAt: currentTime)
            crossfadeCenterCut(to: true)
            return
        }
        let revision = playbackSourceRevision
        centerCutPrepareTask?.cancel()
        centerCutPrepareTask = Task { [weak self] in
            let prepared = try? await Task.detached(priority: .utility) {
                try CenterCutProcessor.prepare(source: sourceURL)
            }.value
            guard let self else { return }
            guard self.centerCutEnabled, self.playbackSourceRevision == revision,
                  let prepared else {
                if let prepared { try? FileManager.default.removeItem(at: prepared) }
                return
            }
            guard let ready = try? AVAudioFile(forReading: prepared,
                                               commonFormat: .pcmFormatFloat32,
                                               interleaved: false) else {
                try? FileManager.default.removeItem(at: prepared)
                self.centerCutEnabled = false
                return
            }
            self.centerCutURL = prepared
            self.centerCutFile = ready
            self.scheduleCenterCut(startingAt: self.currentTime)
            self.crossfadeCenterCut(to: true)
        }
    }

    private func scheduleCenterCut(startingAt time: TimeInterval) {
        guard let file = centerCutFile else { return }
        centerCutPlayer.stop()
        let start = min(max(AVAudioFramePosition(time * file.processingFormat.sampleRate), 0),
                        file.length)
        guard start < file.length else { return }
        centerCutPlayer.scheduleSegment(file, startingFrame: start,
            frameCount: AVAudioFrameCount(min(file.length - start, Int64(UInt32.max))),
            at: nil)
        if isPlaying { centerCutPlayer.play() }
    }

    private func crossfadeCenterCut(to enabled: Bool) {
        let original = player.volume
        let processed = centerCutPlayer.volume
        centerCutRampTask = Task { [weak self] in
            for step in 1...5 {
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled, let self else { return }
                let fraction = CenterCutProcessor.ramp(step)
                self.player.volume = original + ((enabled ? 0 : 1) - original) * fraction
                self.centerCutPlayer.volume = processed + ((enabled ? 1 : 0) - processed) * fraction
            }
            if !enabled { self?.centerCutPlayer.stop() }
        }
    }

    // MARK: Four-stem mixer

    /// Immediate AU parameter events. The AU applies each change to the live
    /// render stream with a 30 ms sample ramp; no file preparation or reschedule.
    private var usesPreparedStemMix: Bool {
        stemMixEnabled && neuralStems.asset != nil &&
            StemKind.allCases.contains { (stemLevels[$0] ?? 1) != 1 }
    }
    private func sendStemParameters() {
        let usesStems = usesPreparedStemMix
        // All 100% is the original recording. A changed mix is the four actual
        // neural files; neither path uses InstantStemMasker's approximation.
        stemMaskNode.auAudioUnit.scheduleParameterBlock(AUEventSampleTimeImmediate, 0, 0, usesStems ? 0 : 1)
        neuralStems.setLevels(stemLevels, enabled: usesStems)
    }

    func cancelStemPreparation(message: String = "") {
        guard let task = stemPreparationTask else {
            stemPreparationProgress = 0
            stemPreparationMessage = message; stemPreparationError = nil
            return
        }
        isCancellingStems = true
        stemPreparationMessage = message.isEmpty ? "Cancelando separação…" : message
        stemPreparationError = nil
        task.cancel()
        // Keep the resource lease until the utility worker acknowledges the
        // cancellation and drains its models. A prediction cannot be preempted.
    }

    func prepareNeuralStemPreview() { prepareNeuralStems(request: .preview(at: currentTime)) }

    func prepareCloudStems(code: String) { prepareNeuralStems(cloudCode: code) }

    func setStemAppBackgrounded(_ backgrounded: Bool) {
        StemWorkLifecycle.shared.setBackgrounded(backgrounded)
        if !backgrounded { endStemBackgroundLease() }
        else if isPreparingStems {
            if !stemPreparationIsCloud {
                stemPreparationMessage = "Pausado em segundo plano · progresso salvo; retoma ao voltar"
            }
            beginStemBackgroundLease()
        }
    }

    private func beginStemBackgroundLease() {
        guard stemBackgroundLease == .invalid else { return }
        stemBackgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Salvar separação") { [weak self] in
            Task { @MainActor in self?.endStemBackgroundLease() }
        }
    }
    private func endStemBackgroundLease() {
        guard stemBackgroundLease != .invalid else { return }
        UIApplication.shared.endBackgroundTask(stemBackgroundLease)
        stemBackgroundLease = .invalid
    }

    func resumeStemPreparation() {
        guard !isPreparingStems, !isExporting, let job = StemJobJournal.load() else { return }
        startStemPreparation(source: job.originalSource, title: job.title,
            kind: job.previewTime.map { .preview(at: $0) } ?? .full,
            cloudCode: job.cloud ? CloudStemBetaCode.read() : nil, restoring: job)
    }

    func restorePendingStemJobIfNeeded() async {
        let saved = await Task.detached(priority: .utility) { StemJobJournal.load() }.value
        guard !isPreparingStems, let saved else { return }
        canResumeStemPreparation = true
        stemPreparationTitle = saved.title
        if saved.automaticResume { resumeStemPreparation() }
    }

    func prepareNeuralStems(request kind: NeuralStemRequest = .full, cloudCode: String? = nil) {
        guard let sourceURL, !isExporting, !isPreparingStems else { return }
        startStemPreparation(source: sourceURL, title: fileName ?? sourceURL.deletingPathExtension().lastPathComponent,
                             kind: kind, cloudCode: cloudCode)
    }

    private func startStemPreparation(source: URL, title: String, kind: NeuralStemRequest,
                                      cloudCode: String?, restoring saved: StemJobJournal? = nil) {
        guard cloudCode != nil || hasNeuralStemModel else {
            stemPreparationError = "A separação neural precisa de iOS 18 ou superior e do modelo incluído no app."
            return
        }
        let request = UUID()
        let prepare: NeuralPreparation
        if let cloudCode {
            prepare = { source, _, _, progress in
                try await CloudStemWorker.prepare(source: source, betaCode: cloudCode, progress: progress)
            }
        } else { prepare = neuralPreparation }
        stemPreparationID = request
        isPreparingStems = true; isCancellingStems = false; canResumeStemPreparation = false
        stemPreparationTitle = title; stemPreparationIsCloud = cloudCode != nil
        stemPreparationProgress = 0; stemPreparationError = nil
        stemPreparationMessage = saved == nil ? "Salvando a música para separar…" : "Retomando separação salva…"
        removeVisualMeterTap()
        beginStemBackgroundLease()
        stemPreparationTask = Task { [weak self] in
            await MusicIntelligenceEngine.shared.suspendForNeuralWork()
            var journal: StemJobJournal?
            defer {
                if let self, self.stemPreparationID == request {
                    self.endStemBackgroundLease()
                    self.isPreparingStems = false; self.isCancellingStems = false
                    self.stemPreparationTask = nil
                    if self.isPlaying { self.installVisualMeterTap() }
                }
                Task { await MusicIntelligenceEngine.shared.resumeAfterNeuralWork() }
            }
            do {
                journal = try await Task.detached(priority: .utility) {
                    if var saved {
                        saved.automaticResume = true; try saved.save(); return saved
                    }
                    return try StemJobJournal.create(source: source, title: title,
                        cloud: cloudCode != nil, preview: kind.previewTime)
                }.value
                guard let journal else { return }
                await NowPlayingArtworkLoader.releaseDecodedCovers()
                try Task.checkCancellation()
                let asset = try await prepare(journal.source, kind, {
                    Task { @MainActor in await NowPlayingArtworkLoader.releaseDecodedCovers() }
                }) { [weak self] value, message in
                    Task { @MainActor in
                        guard let self, self.stemPreparationID == request,
                              self.isPreparingStems, !self.isCancellingStems else { return }
                        if value >= 0 { self.stemPreparationProgress = max(self.stemPreparationProgress, value) }
                        self.stemPreparationMessage = message
                    }
                }
                try Task.checkCancellation()
                await Task.detached(priority: .utility) { journal.remove() }.value
                guard let self, self.stemPreparationID == request else { return }
                self.preparedStemAssets[source] = asset
                self.stemPreparationProgress = 1
                self.stemPreparationMessage = "Stems salvos · \(title) · \(asset.source.title)"
                guard self.sourceURL == source else { return }
                if kind.previewTime != nil {
                    guard asset.preview != nil else { throw NeuralStemError.invalidOutput }
                    self.stemPreview = asset
                    self.stemPreparationMessage = "Prévia pronta · compare o original, a voz e o acompanhamento"
                } else { try self.installPreparedStems(asset) }
            } catch {
                if var journal {
                    if error is CancellationError {
                        await Task.detached(priority: .utility) { journal.remove() }.value
                    } else {
                        journal.automaticResume = false
                        try? await Task.detached(priority: .utility) { try journal.save() }.value
                    }
                }
                guard let self, self.stemPreparationID == request else { return }
                self.canResumeStemPreparation = !(error is CancellationError) && journal != nil
                if !(error is CancellationError) { self.stemPreparationError = error.localizedDescription }
                else if self.stemPreparationMessage == "Cancelando separação…" {
                    self.stemPreparationMessage = "Separação cancelada."
                }
            }
        }
    }

    private func installPreparedStems(_ asset: StemAsset) throws {
        guard let file = audioFile else { return }
        let position = currentTime, resume = isPlaying
        try neuralStems.load(asset, seconds: duration)
        scheduleGeneration += 1
        player.stop(); centerCutPlayer.stop()
        isPlaying = false
        engine.stop()
        neuralStems.connect(engine: engine, mixer: upmix)
        engine.prepare()
        lastKnownTime = position
        schedule(file, startingAt: position)
        if centerCutEnabled { scheduleCenterCut(startingAt: position) }
        stemsAvailable = true; stemSource = asset.source
        if asset.source == .roformer { stemPreview = nil }
        sendStemParameters()
        if resume { play() }
    }

    func applyStemPreset(_ preset: StemMixPreset) {
        stemLevels = preset.levels
        setStemMixerEnabled(true)
    }

    func setStemLevel(_ kind: StemKind, level: Float) {
        stemLevels[kind] = level.clamped(to: Self.stemRange)
        if !stemMixEnabled { setStemMixerEnabled(true) }
        sendStemParameters()
    }

    func resetStemLevels() {
        stemLevels = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, 1) })
        sendStemParameters()
    }

    func setStemMixerEnabled(_ enabled: Bool) {
        stemMixEnabled = enabled
        if enabled {
            centerCutEnabled = false
            centerCutRampTask?.cancel()
            centerCutPlayer.stop()
            centerCutPlayer.volume = 0
            player.volume = 1
        }
        sendStemParameters()
    }
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
        guard !isPreparingStems else { throw AudioEngineError.stemPreparationInProgress }

        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        let settings = RenderSettings(speed: speed, pitch: pitch, reverb: reverb, bass: bass,
                                      reverbPresetRaw: Self.defaultReverbPreset.rawValue)
        let frozen = try storyAudioSource()
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.exportProgress = value }
        }

        let url = try await Task.detached(priority: .userInitiated) {
            try Self.renderOffline(source: sourceURL, settings: settings,
                                   format: format, progress: progress,
                                   stemLevels: frozen.stemLevels, stemAsset: frozen.stemAsset)
        }.value

        exportProgress = 1
        return url
    }

    /// Frozen additive pad-event export reuses the same offline music graph.
    /// The live engine remains untouched. No export is started by a pad tap.
    func exportPerformanceAudio(timeline: PerformanceTimeline,
                                format: ExportFormat = .m4a) async throws -> URL {
        guard !isPreparingStems else { throw AudioEngineError.stemPreparationInProgress }
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
        let frozen = try storyAudioSource()
        let task = Task.detached(priority: .userInitiated) {
            try Self.renderOffline(source: sourceURL, settings: settings,
                                   format: format, progress: { _ in },
                                   performance: timeline, stemLevels: frozen.stemLevels,
                                   stemAsset: frozen.stemAsset)
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
        guard !isPreparingStems else { throw AudioEngineError.stemPreparationInProgress }
        guard let sourceURL else { throw AudioEngineError.noFileLoaded }
        let settings = RenderSettings(speed: speed, pitch: pitch, reverb: reverb, bass: bass,
                                      reverbPresetRaw: Self.defaultReverbPreset.rawValue)
        return StoryAudioSource(url: sourceURL, settings: settings,
                                stemLevels: usesPreparedStemMix ? stemLevels : nil,
                                stemAsset: usesPreparedStemMix ? neuralStems.asset : nil)
    }

    /// Standalone offline graph. Does not seek, pause or replace the live player.
    nonisolated static func exportStorySegment(source: StoryAudioSource,
                                               startTime: TimeInterval,
                                               duration: TimeInterval,
                                               performance: PerformanceTimeline? = nil) async throws -> URL {
        let renderTask = Task.detached(priority: .userInitiated) {
            try Self.renderOffline(source: source.url, settings: source.settings,
                                   format: .m4a, progress: { _ in },
                                   startTime: startTime, maxDuration: duration,
                                   performance: performance,
                                   stemLevels: source.stemLevels, stemAsset: source.stemAsset, fadeEdges: true)
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
        neuralStems.schedule(at: start)
        needsScheduling = false
    }

    func playbackFinished(generation: Int) {
        // Ignora callbacks de agendamentos antigos (stop() também dispara o callback).
        guard !isReconfiguringGraph, generation == scheduleGeneration else { return }
        karaokeCompletion?()
        player.stop()
        neuralStems.stop()
        centerCutPlayer.stop()
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
        neuralStems.stop()
        centerCutPlayer.stop()
        needsScheduling = true
        isPlaying = false
        lastKnownTime = 0
        scheduledStartTime = 0
        lyricsClock.didSeek(to: 0)
    }

    /// One output tap, shared by all background instances. Main actor controls
    /// installation; the CoreAudio callback never captures the engine or UI.
    private func installVisualMeterTap() {
        guard !liveMeterTapInstalled, !isPreparingStems else { return }
        let meter = liveVisualMeter
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) {
            buffer, _ in meter.consume(buffer)
        }
        liveMeterTapInstalled = true
    }

    private func removeVisualMeterTap() {
        guard liveMeterTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        liveMeterTapInstalled = false
        liveVisualMeter.reset()
    }

    // MARK: - Now Playing (Tela de Bloqueio / Control Center)

    /// Cover loading is independent of transport. A late response cannot put
    /// a previous song's thumbnail onto the current Lock Screen card.
    func loadNowPlayingArtwork(coverURL: URL?, mediaURL: URL? = nil) {
        artworkLoadTask?.cancel()
        let revision = playbackSourceRevision
        artworkLoadTask = Task { [weak self] in
            let artwork = await NowPlayingArtworkLoader.load(
                coverURL: coverURL, mediaURL: mediaURL)
            guard !Task.isCancelled, let self,
                  self.playbackSourceRevision == revision else { return }
            self.nowPlayingArtwork = artwork ?? NowPlayingArtworkLoader.officialLogo()
            self.setupNowPlaying()
        }
    }

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

        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = fileName
        info[MPMediaItemPropertyArtist] = "\(mode) · \(String(format: "%.2f×", speed))"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speed) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(speed)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        center.nowPlayingInfo = info
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
            // Prepare input capability before a song is scheduled. A first mic
            // permission grant cannot reset an already playing player node.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("AudioEngineManager: falha ao configurar AVAudioSession – \(error)")
            #endif
        }
    }

    /// Release transient voices at every hardware interruption/route loss.
    /// Never query inputNode on a headless simulator: only disconnect a mic
    /// node that was validated and attached during explicit opt-in capture.
    private func suspendLivePerformanceForSystemEvent() {
        endKaraokeMicrophone()
        stopPerformancePads()
        stopAllCreatorLoops()
        stopPadTake()
        padAccentEmitter.clear()
        vocalGate.outputVolume = 0
        vocalMonitoringEnabled = false
        if let input = connectedVocalInput {
            input.removeTap(onBus: 0)
            engine.disconnectNodeOutput(input)
            connectedVocalInput = nil
        }
        microphoneCapture?.stop()
        microphoneCapture = nil
        vocalCaptureActive = false
        karaokeCompletion = nil
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
                    self.beginGraphReconfiguration()
                    self.suspendLivePerformanceForSystemEvent()
                    self.finishGraphReconfiguration(resume: false)
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
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let removed = reason == .oldDeviceUnavailable
            let hardwareChanged = removed || reason == .newDeviceAvailable
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lyricsClock.refreshOutputLatency()
                self.refreshPerformanceOutputLatency()
                // Hardware input formats and scheduled voices may become
                // invalid during route negotiation. The current song file is
                // retained; no accidental auto-resume on unplug.
                if hardwareChanged && !removed && self.vocalCaptureActive {
                    self.endVocalCapture()
                }
                self.refreshVocalMonitorSafety()
                if removed {
                    self.beginGraphReconfiguration()
                    self.suspendLivePerformanceForSystemEvent()
                    self.interruptedSourceURL = nil
                    self.finishGraphReconfiguration(resume: false)
                }
            }
        }
    }

    // MARK: - Limpeza de cache

    /// Only clean temporary files and import directories OWNED by NightcoreLab.
    /// The shared application temp directory can contain inputs for tests,
    /// share extensions and other features: deleting every audio file here
    /// would destroy a source immediately before load(url:).
    nonisolated static func clearTempAudioFiles(in tempDir: URL = FileManager.default.temporaryDirectory) {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        guard let files = try? fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var freedBytes: Int64 = 0
        for url in files {
            // Only stale files: a deferred cleanup must never delete a new
            // import, a current export or another live engine's center cut.
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            if url.lastPathComponent.hasPrefix("nightcore_import_"),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fileManager.removeItem(at: url)
                continue
            }
            // Old audio exports had arbitrary source-name prefixes. They cannot
            // safely be distinguished from user files, so intentionally keep
            // them rather than deleting someone else's temporary WAV.
            let owned = url.lastPathComponent.hasPrefix("nightcore_export_") ||
                        url.lastPathComponent.hasPrefix("NightcorePerformance-") ||
                        url.lastPathComponent.hasPrefix("nightcore_center_cut_")
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

    nonisolated static func connectGraph(engine: AVAudioEngine,
                                                 player: AVAudioPlayerNode,
                                                 upmix: AVAudioMixerNode,
                                                 varispeed: AVAudioUnitVarispeed,
                                                 timePitch: AVAudioUnitTimePitch,
                                                 eq: AVAudioUnitEQ,
                                                 reverb: AVAudioUnitReverb,
                                                 limiter: AVAudioUnitEffect,
                                                 fileFormat: AVAudioFormat,
                                                 graphFormat: AVAudioFormat,
                                                 performanceMixer: AVAudioMixerNode? = nil,
                                                 originalGain: (mixer: AVAudioMixerNode, gain: AVAudioUnitEffect)? = nil) {
        // O mixer converte mono→estéreo e taxa de amostragem, deixando o resto do grafo uniforme.
        if let originalGain {
            // Gate ONLY the original recording before it joins the real stems.
            // Putting this gain after EQ would mute the entire combined mix.
            engine.connect(player, to: originalGain.mixer, format: fileFormat)
            engine.connect(originalGain.mixer, to: originalGain.gain, format: graphFormat)
            engine.connect(originalGain.gain, to: upmix, format: graphFormat)
        } else {
            engine.connect(player, to: upmix, format: fileFormat)
        }
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
                                                  performance: PerformanceTimeline? = nil,
                                                  stemLevels: [StemKind: Float]? = nil,
                                                  stemAsset: StemAsset? = nil,
                                                  fadeEdges: Bool = false) throws -> URL {
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
        let realStems = stemAsset == nil || stemLevels == nil ? nil : NeuralStemPlayback()
        let originalUpmix = AVAudioMixerNode()
        let originalGain = StemGainAudioUnit.makeNode(initialGain: realStems == nil ? 1 : 0)
        engine.attach(originalUpmix); engine.attach(originalGain)
        realStems?.nodes.forEach { engine.attach($0) }
        if let realStems, let stemAsset {
            try realStems.load(stemAsset, seconds: sourceSeconds)
        }
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
                     performanceMixer: performanceMixer,
                     originalGain: (originalUpmix, originalGain))
        realStems?.connect(engine: engine, mixer: upmix)
        if let stemLevels {
            guard realStems != nil else { throw NeuralStemError.invalidOutput }
            realStems?.setLevels(stemLevels, enabled: true, immediate: true)
        }
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
        realStems?.schedule(at: maxDuration == nil ? 0 : startTime)
        realStems?.play(at: nil)
        if let padPlayer, let padFile {
            padPlayer.scheduleFile(padFile, at: nil)
            padPlayer.play()
        }
        defer {
            padPlayer?.stop()
            realStems?.stop()
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
                if fadeEdges, let channels = buffer.floatChannelData {
                    let fadeInFrames = max(1, Int(0.120 * outputRate))
                    let fadeOutFrames = max(1, Int(0.180 * outputRate))
                    for index in 0..<Int(buffer.frameLength) {
                        let absolute = rendered + AVAudioFramePosition(index)
                        let incoming = min(1, Double(absolute) / Double(fadeInFrames))
                        let outgoing = min(1, Double(totalFrames - 1 - absolute) /
                                           Double(fadeOutFrames))
                        let gain = Float(sin(.pi * 0.5 * max(0, min(incoming, outgoing))))
                        for channel in 0..<Int(buffer.format.channelCount) {
                            channels[channel][index] *= gain
                        }
                    }
                }
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


/// Container probing is disk I/O; graph installation remains on the main actor.
enum AudioFilePreparation {
    private static let queue = DispatchQueue(label: "nightcore.audio.open", qos: .utility)
    static func open(_ url: URL) async throws -> AVAudioFile {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                })
            }
        }
    }
    static func remove(_ url: URL) {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}
