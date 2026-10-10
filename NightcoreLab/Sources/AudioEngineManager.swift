import AVFoundation
import AudioToolbox
import MediaPlayer
import Observation
import UniformTypeIdentifiers

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
    private let upmix = AVAudioMixerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let timePitch = AudioEngineManager.makeTimePitch()
    private let bassEQ = AudioEngineManager.makeBassEQ()
    private let reverbNode = AudioEngineManager.makeReverb()
    private let limiter = AudioEngineManager.makeLimiter()

    /// Ordem da cadeia, usada para attach e para desconectar ao trocar de música.
    private var processingNodes: [AVAudioNode] { [player, upmix, varispeed, timePitch, bassEQ, reverbNode, limiter] }

    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var needsScheduling = true
    @ObservationIgnored private var scheduleGeneration = 0
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastKnownTime: TimeInterval = 0
    @ObservationIgnored private var scheduledStartTime: TimeInterval = 0

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

        Self.configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: speed, pitch: pitch)
        bassEQ.bands[0].gain = bass
        reverbNode.wetDryMix = reverb
    }

    // MARK: Carregar arquivo

    func load(url: URL) throws {
        // Core Audio decodifica MP3/AAC para PCM float; não há conversão com perdas na importação.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              (1...2).contains(file.processingFormat.channelCount) else {
            throw AudioEngineError.unsupportedAudio
        }
        stopPlayback()
        audioFile = file
        sourceURL = url
        fileName = url.deletingPathExtension().lastPathComponent
        duration = Double(file.length) / file.processingFormat.sampleRate

        engine.stop()
        processingNodes.forEach { engine.disconnectNodeOutput($0) }

        let graphFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate,
                                        channels: 2)!
        Self.connectGraph(engine: engine, player: player, upmix: upmix,
                          varispeed: varispeed, timePitch: timePitch, eq: bassEQ, reverb: reverbNode, limiter: limiter,
                          fileFormat: file.processingFormat, graphFormat: graphFormat)
        engine.prepare()
        needsScheduling = true
        scheduledStartTime = 0
        lastKnownTime = 0
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

    // MARK: - Privado: playback

    private func schedule(_ file: AVAudioFile, startingAt start: TimeInterval = 0) {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        let startFrame = min(max(AVAudioFramePosition(start * file.processingFormat.sampleRate), 0), file.length)
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        scheduledStartTime = start
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
        needsScheduling = true
        isPlaying = false
        lastKnownTime = 0
        scheduledStartTime = 0
        setupNowPlaying()
        playbackCompletionCount += 1
    }

    private func stopPlayback() {
        scheduleGeneration += 1
        player.stop()
        needsScheduling = true
        isPlaying = false
        lastKnownTime = 0
        scheduledStartTime = 0
    }

    // MARK: - Now Playing (Tela de Bloqueio / Control Center)

    /// Posição atual em segundos da música original (antes do speed).
    private var currentTime: TimeInterval {
        guard !needsScheduling,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return needsScheduling ? 0 : lastKnownTime
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
                                                 varispeed: AVAudioUnitVarispeed,
                                                 timePitch: AVAudioUnitTimePitch,
                                                 eq: AVAudioUnitEQ,
                                                 reverb: AVAudioUnitReverb,
                                                 limiter: AVAudioUnitEffect,
                                                 fileFormat: AVAudioFormat,
                                                 graphFormat: AVAudioFormat) {
        // O mixer converte mono→estéreo e taxa de amostragem, deixando o resto do grafo uniforme.
        engine.connect(player, to: upmix, format: fileFormat)
        engine.connect(upmix, to: varispeed, format: graphFormat)
        engine.connect(varispeed, to: timePitch, format: graphFormat)
        engine.connect(timePitch, to: eq, format: graphFormat)
        engine.connect(eq, to: reverb, format: graphFormat)
        // Limiter por último: segura os picos somados de graves + cauda do reverb.
        engine.connect(reverb, to: limiter, format: graphFormat)
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
                                                  progress: @Sendable (Double) -> Void) throws -> URL {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceRate = file.processingFormat.sampleRate
        guard file.length > 0, sourceRate > 0, (1...2).contains(file.processingFormat.channelCount),
              speedRange.contains(settings.speed), pitchRange.contains(settings.pitch),
              reverbRange.contains(settings.reverb), bassRange.contains(settings.bass) else {
            throw AudioEngineError.unsupportedAudio
        }
        // AAC em taxas convencionais; WAV mantém a taxa original.
        let outputRate = format == .m4a ? (sourceRate == 44_100 ? 44_100.0 : 48_000.0) : sourceRate

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

        configurePlayback(varispeed: varispeed, timePitch: timePitch, speed: settings.speed, pitch: settings.pitch)
        eq.bands[0].gain = settings.bass
        eq.globalGain = -settings.bass
        reverb.loadFactoryPreset(AVAudioUnitReverbPreset(rawValue: settings.reverbPresetRaw) ?? defaultReverbPreset)
        reverb.wetDryMix = settings.reverb
        reverb.bypass = settings.reverb == 0

        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        connectGraph(engine: engine, player: player, upmix: upmix, varispeed: varispeed, timePitch: timePitch, eq: eq,
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
            .appendingPathComponent("\(baseName)_\(tag)_\(UUID().uuidString.prefix(8)).\(format.rawValue)")
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

