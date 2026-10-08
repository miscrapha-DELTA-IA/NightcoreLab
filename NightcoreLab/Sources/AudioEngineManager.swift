import AVFoundation
import AudioToolbox
import MediaPlayer
import Observation
import UniformTypeIdentifiers

// MARK: - Tipos de apoio

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, wav
    var id: String { rawValue }
}

enum AudioEngineError: LocalizedError {
    case noFileLoaded
    case bufferAllocationFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noFileLoaded:            return "Nenhuma música carregada."
        case .bufferAllocationFailed:  return "Não foi possível alocar o buffer de áudio."
        case .renderFailed:            return "Falha ao renderizar o áudio."
        }
    }
}

/// Snapshot dos parâmetros usados no export offline (Sendable para cruzar threads).
private struct RenderSettings: Sendable {
    let speed: Float
    let pitch: Float
    let reverb: Float
    let bass: Float
    let reverbPresetRaw: Int
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
    static let bassFrequency: Float = 200.0                // Hz (corpo da batida, igual à extensão)
    static let bassBandwidth: Float = 1.0                  // oitavas
    static let defaultReverbPreset: AVAudioUnitReverbPreset = .mediumHall   // decay mais próximo dos 2 s da extensão
    static let limiterThreshold: Float = 0.0               // dB: teto invisível, só age no limite
    static let limiterHeadroom: Float = 0.1                // dB (joelho duro → limiter)
    static let limiterAttack: Float = 0.001                // s
    static let limiterRelease: Float = 0.05                // s
    /// Sobreposição do algoritmo de time-stretch (3…32, padrão 8). Mais alto = menos
    /// artefatos metálicos ao acelerar/desacelerar, com um pouco mais de CPU.
    static let timePitchOverlap: Float = 16

    // Estado observável pela UI
    private(set) var isPlaying = false
    private(set) var fileName: String?
    private(set) var duration: TimeInterval = 0
    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0

    private(set) var speed: Float = 1.0
    private(set) var pitch: Float = 0
    private(set) var reverb: Float = 0
    private(set) var bass: Float = 0

    // Grafo de áudio (masterização):
    // player → upmix (estéreo) → timePitch → EQ low shelf → reverb medium hall → limiter → mainMixer → saída
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let upmix = AVAudioMixerNode()
    private let timePitch = AudioEngineManager.makeTimePitch()
    private let bassEQ = AudioEngineManager.makeBassEQ()
    private let reverbNode = AudioEngineManager.makeReverb()
    private let limiter = AudioEngineManager.makeLimiter()

    /// Ordem da cadeia, usada para attach e para desconectar ao trocar de música.
    private var processingNodes: [AVAudioNode] { [player, upmix, timePitch, bassEQ, reverbNode, limiter] }

    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var needsScheduling = true
    @ObservationIgnored private var scheduleGeneration = 0
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastKnownTime: TimeInterval = 0

    init() {
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

        timePitch.rate = speed
        timePitch.pitch = pitch
        bassEQ.bands[0].gain = bass
        reverbNode.wetDryMix = reverb
    }

    // MARK: Carregar arquivo

    func load(url: URL) throws {
        stopPlayback()

        let file = try AVAudioFile(forReading: url)
        audioFile = file
        sourceURL = url
        fileName = url.deletingPathExtension().lastPathComponent
        duration = Double(file.length) / file.processingFormat.sampleRate

        engine.stop()
        processingNodes.forEach { engine.disconnectNodeOutput($0) }

        let graphFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate,
                                        channels: 2)!
        Self.connectGraph(engine: engine, player: player, upmix: upmix,
                          timePitch: timePitch, eq: bassEQ, reverb: reverbNode, limiter: limiter,
                          fileFormat: file.processingFormat, graphFormat: graphFormat)
        engine.prepare()
        needsScheduling = true
        setupNowPlaying()
    }

    // MARK: Transporte

    func play() {
        guard let file = audioFile else { return }
        do {
            if !engine.isRunning { try engine.start() }
            if needsScheduling { schedule(file) }
            player.play()
            isPlaying = true
            setupNowPlaying()
        } catch {
            print("AudioEngineManager: falha ao iniciar engine – \(error)")
        }
    }

    func pause() {
        lastKnownTime = currentTime   // captura antes de pausar, enquanto lastRenderTime é válido
        player.pause()
        isPlaying = false
        setupNowPlaying()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    // MARK: Parâmetros em tempo real

    func setSpeed(_ value: Float) {
        speed = value.clamped(to: Self.speedRange)
        timePitch.rate = speed
        setupNowPlaying()   // a barra de progresso da tela de bloqueio acompanha a nova velocidade
    }

    func setPitch(_ value: Float) {
        pitch = value.clamped(to: Self.pitchRange)
        timePitch.pitch = pitch
    }

    func setReverb(_ value: Float) {
        reverb = value.clamped(to: Self.reverbRange)
        reverbNode.wetDryMix = reverb
    }

    /// Ganho do low shelf em 200 Hz, de 0 a 12 dB. Só o ganho muda; tipo, frequência
    /// e largura ficam fixos. Sem redução manual de volume: o limiter é só um teto em 0 dBFS.
    func setBass(_ value: Float) {
        bass = value.clamped(to: Self.bassRange)
        bassEQ.bands[0].gain = bass
    }

    // MARK: Export offline

    /// Renderiza a música inteira com os parâmetros atuais (mais rápido que tempo real)
    /// e devolve a URL do arquivo no diretório temporário.
    func exportAudio(format: ExportFormat = .m4a) async throws -> URL {
        guard let sourceURL else { throw AudioEngineError.noFileLoaded }

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

    // MARK: - Privado: playback

    private func schedule(_ file: AVAudioFile) {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.playbackFinished(generation: generation) }
        }
        needsScheduling = false
    }

    private func playbackFinished(generation: Int) {
        // Ignora callbacks de agendamentos antigos (stop() também dispara o callback).
        guard generation == scheduleGeneration else { return }
        player.stop()
        needsScheduling = true
        isPlaying = false
        lastKnownTime = 0
        setupNowPlaying()
    }

    private func stopPlayback() {
        scheduleGeneration += 1
        player.stop()
        needsScheduling = true
        isPlaying = false
        lastKnownTime = 0
    }

    // MARK: - Now Playing (Tela de Bloqueio / Control Center)

    /// Posição atual em segundos da música original (antes do speed).
    private var currentTime: TimeInterval {
        guard !needsScheduling,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return needsScheduling ? 0 : lastKnownTime
        }
        let seconds = Double(playerTime.sampleTime) / playerTime.sampleRate
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
    }

    private func setupRemoteTransportControls() {
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }

        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        // Fones com botão único e o botão central dos AirPods usam este comando.
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }

        // Sem playlist nem seek: esconde esses controles para não aparecerem botões mortos.
        [commands.nextTrackCommand,
         commands.previousTrackCommand,
         commands.skipForwardCommand,
         commands.skipBackwardCommand,
         commands.changePlaybackPositionCommand,
         commands.changePlaybackRateCommand].forEach { $0.isEnabled = false }
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
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.pause() }
        }

        // Fone desconectado (cabo puxado, AirPods fora do ouvido/desligados):
        // pausa para o som não sair de repente pelo alto-falante.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        }
    }

    // MARK: - Limpeza de cache

    /// Apaga do diretório temporário os áudios de sessões anteriores: exports (.m4a/.wav)
    /// e as cópias de músicas importadas (.mp3, .aac, .flac…).
    /// Roda de forma síncrona no init: nada está carregado ainda, e assim não há risco
    /// de apagar um arquivo que o usuário acabou de importar.
    private func clearTempAudioFiles() {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory

        guard let files = try? fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var freedBytes: Int64 = 0
        for url in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
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
                                                 timePitch: AVAudioUnitTimePitch,
                                                 eq: AVAudioUnitEQ,
                                                 reverb: AVAudioUnitReverb,
                                                 limiter: AVAudioUnitEffect,
                                                 fileFormat: AVAudioFormat,
                                                 graphFormat: AVAudioFormat) {
        // O mixer converte mono→estéreo e taxa de amostragem, deixando o resto do grafo uniforme.
        engine.connect(player, to: upmix, format: fileFormat)
        engine.connect(upmix, to: timePitch, format: graphFormat)
        engine.connect(timePitch, to: eq, format: graphFormat)
        engine.connect(eq, to: reverb, format: graphFormat)
        // Limiter por último: segura os picos somados de graves + cauda do reverb.
        engine.connect(reverb, to: limiter, format: graphFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: graphFormat)
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
        eq.globalGain = 0                       // sem compensação manual: quem protege é o limiter
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
        return reverb
    }

    /// Brickwall de proteção usando o AUDynamicsProcessor da Apple:
    /// threshold 0 dB com headroom de 0.1 dB: teto invisível, sem compressão abaixo do limite.
    nonisolated private static func makeLimiter() -> AVAudioUnitEffect {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
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
        set(kDynamicsProcessorParam_Threshold, limiterThreshold)
        set(kDynamicsProcessorParam_HeadRoom, limiterHeadroom)
        set(kDynamicsProcessorParam_AttackTime, limiterAttack)
        set(kDynamicsProcessorParam_ReleaseTime, limiterRelease)
        set(kDynamicsProcessorParam_ExpansionRatio, 1)   // expander desligado: só limitação
        return limiter
    }

    nonisolated private static func renderOffline(source: URL,
                                                  settings: RenderSettings,
                                                  format: ExportFormat,
                                                  progress: @Sendable (Double) -> Void) throws -> URL {
        let file = try AVAudioFile(forReading: source)
        let sourceRate = file.processingFormat.sampleRate
        // AAC suporta no máximo 48 kHz.
        let outputRate = format == .m4a ? min(sourceRate, 48_000) : sourceRate

        // Engine separada: o export não interrompe o playback.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let upmix = AVAudioMixerNode()
        let timePitch = makeTimePitch()
        let eq = makeBassEQ()
        let reverb = makeReverb()
        let limiter = makeLimiter()
        [player, upmix, timePitch, eq, reverb, limiter].forEach { engine.attach($0) }

        timePitch.rate = settings.speed
        timePitch.pitch = settings.pitch
        eq.bands[0].gain = settings.bass
        reverb.loadFactoryPreset(AVAudioUnitReverbPreset(rawValue: settings.reverbPresetRaw) ?? defaultReverbPreset)
        reverb.wetDryMix = settings.reverb

        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        connectGraph(engine: engine, player: player, upmix: upmix, timePitch: timePitch, eq: eq,
                     reverb: reverb, limiter: limiter,
                     fileFormat: file.processingFormat, graphFormat: renderFormat)

        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(file, at: nil)
        player.play()
        defer {
            player.stop()
            engine.stop()
        }

        // Duração final = duração original / speed + cauda do reverb.
        let sourceSeconds = Double(file.length) / sourceRate
        let tailSeconds = settings.reverb > 0 ? 3.0 : 0.1
        let totalFrames = AVAudioFramePosition((sourceSeconds / Double(settings.speed) + tailSeconds) * outputRate)

        // Arquivo de saída
        let baseName = source.deletingPathExtension().lastPathComponent
        let tag = settings.speed >= 1 ? "nightcore" : "slowed"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)_\(tag).\(format.rawValue)")
        try? FileManager.default.removeItem(at: outputURL)

        let fileSettings: [String: Any]
        switch format {
        case .m4a:
            fileSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: outputRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000
            ]
        case .wav:
            fileSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: outputRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
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

        while rendered < totalFrames {
            let remaining = totalFrames - rendered
            let framesToRender = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))

            switch try engine.renderOffline(framesToRender, to: buffer) {
            case .success:
                try outputFile.write(from: buffer)
                rendered += AVAudioFramePosition(buffer.frameLength)

                let fraction = Double(rendered) / Double(totalFrames)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw AudioEngineError.renderFailed
            @unknown default:
                throw AudioEngineError.renderFailed
            }
        }

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
