import SwiftUI
import UIKit
import AVFoundation

/// Stable per-finger accounting: ending/cancelling one UITouch must not
/// release the pressed appearance while another finger is still down.
struct PadTouchState {
    private(set) var active: Set<ObjectIdentifier> = []
    var isPressed: Bool { !active.isEmpty }

    mutating func begin(_ id: ObjectIdentifier) -> Bool {
        active.insert(id).inserted
    }
    mutating func end(_ id: ObjectIdentifier) -> Bool {
        active.remove(id) != nil
    }
    mutating func reset() { active.removeAll(keepingCapacity: true) }
}

/// A repeatable musical velocity curve: stable input → stable event velocity.
/// Finger area/pressure is not guaranteed on iPhone, so use vertical zone.
enum PadExpressiveness {
    static func velocity(verticalZone: Float?, base: Float, hitIndex: Int) -> Float {
        guard base.isFinite else { return 0.85 }
        let normalized: Float
        if let verticalZone, verticalZone.isFinite {
            normalized = min(1, max(0, verticalZone))
        } else {
            return min(1, max(0.05, base))
        }
        // Fixed four-step gain alternation; no per-touch Array allocation.
        let accent: Float
        switch hitIndex % 4 {
        case 1: accent = 0.982
        case 2: accent = 1.014
        case 3: accent = 0.994
        default: accent = 1
        }
        let gain: Float = 0.60 + 0.40 * normalized
        return min(1, max(0.05, base * gain * accent))
    }
}

/// UIKit delivers each UITouch identity directly. No Button release-to-fire
/// delay, SwiftUI DragGesture, gesture-disambiguation or async audio hop.
private final class PadTouchControl: UIControl {
    var onStrike: ((UITouch, UIView) -> Void)?
    var onPressedChanged: ((Bool) -> Void)?
    private var touchState = PadTouchState()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for touch in touches where touchState.begin(ObjectIdentifier(touch)) {
            onStrike?(touch, self)
        }
        onPressedChanged?(touchState.isPressed)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for touch in touches { _ = touchState.end(ObjectIdentifier(touch)) }
        onPressedChanged?(touchState.isPressed)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for touch in touches { _ = touchState.end(ObjectIdentifier(touch)) }
        onPressedChanged?(touchState.isPressed)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            touchState.reset()
            onPressedChanged?(false)
        }
    }
}

private struct PadTouchSurface: UIViewRepresentable {
    let name: String
    let onDown: (TimeInterval, Float) -> Bool
    let onPressedChanged: (Bool) -> Void
    let haptics: Bool

    final class Coordinator {
        var onDown: (TimeInterval, Float) -> Bool
        var onPressedChanged: (Bool) -> Void
        var haptics: Bool
        var hitIndex = 0
        private let generator = UIImpactFeedbackGenerator(style: .rigid)

        init(onDown: @escaping (TimeInterval, Float) -> Bool,
             onPressedChanged: @escaping (Bool) -> Void, haptics: Bool) {
            self.onDown = onDown
            self.onPressedChanged = onPressedChanged
            self.haptics = haptics
            if haptics { generator.prepare() }
        }

        func updateHaptics(_ enabled: Bool) {
            if enabled && !haptics { generator.prepare() }
            haptics = enabled
        }

        func begin(_ touch: UITouch, in view: UIView) {
            let vertical = view.bounds.height > 0
                ? Float(1 - touch.location(in: view).y / view.bounds.height)
                : Float.nan
            let index = hitIndex
            hitIndex &+= 1
            // Audio submission returns before any SwiftUI heldPads mutation.
            let played = onDown(touch.timestamp, PadExpressiveness.velocity(
                verticalZone: vertical, base: 0.85, hitIndex: index))
            if played && haptics {
                generator.impactOccurred(intensity: 0.85)
                generator.prepare()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDown: onDown, onPressedChanged: onPressedChanged,
                    haptics: haptics)
    }

    func makeUIView(context: Context) -> PadTouchControl {
        let view = PadTouchControl()
        view.isExclusiveTouch = false
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.accessibilityLabel = "Tocar \(name)"
        view.onStrike = { [weak coordinator = context.coordinator] touch, control in
            coordinator?.begin(touch, in: control)
        }
        view.onPressedChanged = { [weak coordinator = context.coordinator] isPressed in
            coordinator?.onPressedChanged(isPressed)
        }
        return view
    }

    func updateUIView(_ view: PadTouchControl, context: Context) {
        context.coordinator.onDown = onDown
        context.coordinator.onPressedChanged = onPressedChanged
        context.coordinator.updateHaptics(haptics)
        view.accessibilityLabel = "Tocar \(name)"
    }
}

/// Only visible after explicitly entering Performance Mode. Never overlays
/// the premium Player or Karaoke. Its sound is produced by AudioEngineManager.
struct PerformanceModeView: View {
    let audio: AudioEngineManager
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var recorder: PerformanceRecorder { audio.performanceRecorder }
    @AppStorage("performance.grooveStrength") private var grooveStrength: Double = 0
    @State private var padRhythm: RhythmAnalysisResult?
    @State private var padRhythmTask: Task<Void, Never>?
    @State private var haptics = false
    @State private var heldPads: Set<String> = []
    @State private var recordedSourceRevision: Int?
    @State private var isRenderingAudio = false
    @State private var exportedAudio: URL?
    @State private var renderError: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var clipTask: Task<Void, Never>?
    @State private var clipStart: Double = 0
    @State private var clipLength: Double = 2
    @State private var sourceClip: PerformanceSourceClip?
    @State private var recordedClip: PerformanceSourceClip?
    @State private var preparingClip = false
    @State private var confirmSharingRights = false
    @State private var latencyResult: PadLatencySummary?
    @State private var latencyCaptureActive = false
    @State private var latencyScenario: PadCaptureScenario = .warm
    @State private var activeLatencyContext: PadLatencyCaptureContext?
    @State private var latencySessions: [PadLatencyEvidenceSession] = []

    private let grid = [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            // Instrument-grade touch surfaces must NOT be descendants of a
            // scrolling container: UIScrollView may defer UIControl touchDown
            // while deciding whether the gesture intends to scroll.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LIVE PERFORMANCE")
                            .font(.caption.weight(.heavy)).tracking(3)
                            .foregroundStyle(accent)
                        Text("Toque. Misture. Crie.")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("7 sons originais, pré-carregados. Toque com vários dedos enquanto a música continua.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.63))
                    }

                    HStack(spacing: 8) {
                        Image(systemName: audio.isPlaying ? "waveform" : "music.note")
                            .foregroundStyle(accent)
                        Text(audio.isPlaying ? "Música + pads" : "Pads independentes")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("12 VOZES")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                    LazyVGrid(columns: grid, spacing: 8) {
                        ForEach(audio.performanceKit.samples) { sample in
                            pad(sample)
                        }
                        if let sourceClip {
                            pad(sourceClip.descriptor)
                        }
                    }
                    .accessibilityIdentifier("performance.fixedPadDeck")
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 10)

                // Settings, samples, recording and diagnostics may scroll.
                // Pad touch surfaces above are siblings, NOT scroll children.
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        sourceClipPicker

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "record.circle")
                                .foregroundStyle(recorder.isRecording ? .red : accent)
                            Text("CAPTURAR EVENTOS")
                                .font(.caption.weight(.bold)).tracking(1.6)
                            Spacer()
                            Text("\(recorder.events.count) ações")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button {
                                if recorder.isRecording { audio.stopPadTake() }
                                else {
                                    recordedSourceRevision = audio.playbackSourceRevision
                                    recordedClip = sourceClip
                                    audio.beginPadTake()
                                    exportedAudio = nil
                                }
                            } label: {
                                Label(recorder.isRecording ? "Parar" : "Gravar",
                                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                                    .frame(maxWidth: .infinity)
                                    .padding(12)
                                    .background(recorder.isRecording ? Color.red.opacity(0.22) :
                                        accent.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .accessibilityIdentifier("performance.record")
                            if !recorder.isRecording && !recorder.events.isEmpty {
                                Button {
                                    recordedSourceRevision = audio.playbackSourceRevision
                                    audio.beginPadTake(overdub: true)
                                    exportedAudio = nil
                                } label: {
                                    Label("Overdub", systemImage: "plus.circle.fill")
                                }
                                .accessibilityIdentifier("performance.overdub")
                            }

                            if !recorder.events.isEmpty && !recorder.isRecording,
                               let payload = recorder.shareJSON(
                                   sourceClip: recordedClip,
                                   quantizeStrength: Float(grooveStrength)) {
                                ShareLink(item: payload,
                                          subject: Text("NightcoreLab Performance Events"),
                                          message: Text("Sequência de pads NightcoreLab (JSON v1)")) {
                                    Label("Compartilhar eventos", systemImage: "square.and.arrow.up")
                                        .padding(12)
                                        .background(.white.opacity(0.08),
                                                    in: RoundedRectangle(cornerRadius: 12))
                                }
                                .accessibilityIdentifier("performance.shareEvents")
                            }
                        }
                        if !recorder.takeEventIDs.isEmpty && !recorder.isRecording {
                            Button(role: .destructive) {
                                audio.clearLastPadTake()
                                exportedAudio = nil
                            } label: {
                                Label("Limpar último take", systemImage: "arrow.uturn.backward")
                            }
                            .accessibilityIdentifier("performance.clearLastTake")
                        }
                        HStack {
                            Text("Groove assistido")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int((grooveStrength * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $grooveStrength, in: 0...1, step: 0.1)
                            .tint(accent)
                            .accessibilityIdentifier("performance.grooveStrength")
                        Text("0% preserva o toque original. Com grade rítmica disponível, 100% aproxima a gravação da semicolcheia mais próxima. O áudio do toque ao vivo não muda.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("A captura guarda ações e tempos em memória. Você pode compartilhar os eventos em JSON e, com música carregada, renderizar um M4A com os pads. Exportação de Story com pads é etapa posterior.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

                    if !recorder.isRecording && !recorder.events.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                renderPerformanceAudio()
                            } label: {
                                HStack {
                                    Image(systemName: "waveform.badge.plus")
                                    Text(isRenderingAudio ? "Renderizando áudio…" : "Criar música + pads (M4A)")
                                    Spacer()
                                    if isRenderingAudio { ProgressView() }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity)
                                .background(accent.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(isRenderingAudio || audio.isExporting ||
                                      audio.fileName == nil ||
                                      recordedSourceRevision != audio.playbackSourceRevision)
                            .accessibilityIdentifier("performance.renderAudio")

                            if let exportedAudio {
                                ShareLink(item: exportedAudio) {
                                    Label("Compartilhar áudio com pads", systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .accessibilityIdentifier("performance.shareAudio")
                            }
                            if audio.fileName == nil {
                                Text("Carregue uma música para exportar o áudio misturado. Os pads funcionam sem música.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else if recordedSourceRevision != audio.playbackSourceRevision {
                                Text("A faixa foi alterada. Inicie uma nova gravação para exportar áudio com segurança.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    }

                    padDiagnostics

                    Toggle("Feedback tátil", isOn: $haptics)
                        .font(.subheadline)
                        .tint(accent)
                    Text("Os sons são sínteses originais do app — nenhum sample comercial.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.50))
                    }
                    .padding(20)
                }
            }
            .background(Color(red: 0.045, green: 0.055, blue: 0.075))
            .navigationTitle("Performance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
        .alert("Exportação da performance", isPresented: Binding(
            get: { renderError != nil },
            set: { if !$0 { renderError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renderError ?? "")
        }
        .onChange(of: grooveStrength) { _, next in
            audio.padQuantizeStrength = Float(next)
        }
        .onChange(of: audio.playbackSourceRevision) { _, _ in
            clipTask?.cancel()
            preparingClip = false
            sourceClip = nil
            recordedClip = nil
            confirmSharingRights = false
            if recorder.isRecording { audio.stopPadTake() }
            exportedAudio = nil
            prepareMusicalGrid()
        }
        .onAppear {
            audio.beginPerformanceMode()
            audio.padQuantizeStrength = Float(grooveStrength)
            prepareMusicalGrid()
        }
        .onDisappear {
            audio.padLatencyProbe.cancel()
            latencyCaptureActive = false
            activeLatencyContext = nil
            clipTask?.cancel()
            exportTask?.cancel()
            padRhythmTask?.cancel()
            padRhythm = nil
            heldPads.removeAll()
            audio.stopPadTake()
            audio.endPerformanceMode()
        }
    }

    @ViewBuilder
    private var sourceClipPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("SAMPLE PICKER", systemImage: "waveform.badge.plus")
                    .font(.caption.weight(.bold)).tracking(1.5)
                Spacer()
                Text("0,25–5 s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if audio.duration >= PerformanceSourceClip.minLength {
                let lastStart = max(0, audio.duration - PerformanceSourceClip.minLength)
                Text("Início: \(clipStart, specifier: "%.2f") s")
                    .font(.caption)
                Slider(value: $clipStart, in: 0...lastStart)
                    .tint(accent)
                    .accessibilityIdentifier("performance.clipStart")
                let upperLength = max(PerformanceSourceClip.minLength,
                                      min(PerformanceSourceClip.maxLength,
                                          audio.duration - clipStart))
                Text("Duração: \(min(clipLength, upperLength), specifier: "%.2f") s")
                    .font(.caption)
                Slider(value: $clipLength,
                       in: PerformanceSourceClip.minLength...upperLength)
                    .tint(accent)
                    .accessibilityIdentifier("performance.clipLength")

                Toggle("Tenho autorização para usar e compartilhar esse trecho",
                       isOn: $confirmSharingRights)
                    .font(.caption)
                    .tint(accent)
                Button {
                    prepareSourceClip()
                } label: {
                    HStack {
                        Label(sourceClip == nil ? "Atribuir ao pad CLIP" : "Atualizar pad CLIP",
                              systemImage: "square.stack.3d.up")
                        Spacer()
                        if preparingClip { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(preparingClip || recorder.isRecording ||
                          isRenderingAudio || !confirmSharingRights)
                .accessibilityIdentifier("performance.assignClip")

                if sourceClip != nil {
                    Text("Pad CLIP pronto: toque no oitavo pad. O trecho usa PCM local e não é salvo permanentemente.")
                        .font(.caption2)
                        .foregroundStyle(accent)
                }
            } else {
                Text("Carregue uma música local para selecionar um trecho. O kit original funciona sem música.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func prepareSourceClip() {
        guard let url = audio.visualAnalysisURL, url.isFileURL,
              !preparingClip, !recorder.isRecording, confirmSharingRights else { return }
        let revision = audio.playbackSourceRevision
        let duration = min(clipLength, audio.duration - clipStart,
                           PerformanceSourceClip.maxLength)
        guard duration >= PerformanceSourceClip.minLength else { return }
        preparingClip = true
        clipTask?.cancel()
        clipTask = Task { @MainActor in
            defer { preparingClip = false; clipTask = nil }
            do {
                let clip = try await audio.assignPerformanceSourceClip(
                    startTime: clipStart, duration: duration,
                    expectedRevision: revision)
                guard !Task.isCancelled,
                      revision == audio.playbackSourceRevision else { return }
                sourceClip = clip
                recordedClip = nil
                // A new assignment changes the pad material. Old events
                // must not silently replay against a different source clip.
                recorder.start()
                recorder.stop()
                exportedAudio = nil
            } catch is CancellationError {
                // Track replacement or dismissal invalidated preparation.
            } catch {
                renderError = "Não foi possível preparar o trecho: \(error.localizedDescription)"
            }
        }
    }

    private func pad(_ sample: SampleDescriptor) -> some View {
        let active = heldPads.contains(sample.id)
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(active ? accent.opacity(0.22) : .white.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(active ? accent.opacity(0.8) :
                                        .white.opacity(0.14), lineWidth: 1.5)
                }

            VStack(spacing: 9) {
                Image(systemName: symbol(for: sample.id))
                    .font(.title2)
                    .foregroundStyle(active ? accent : .white.opacity(0.84))
                Text(sample.name)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 90)
        .overlay {
            PadTouchSurface(name: sample.name, onDown: { touchTimestamp, touchVelocity in
                strike(sample, velocity: touchVelocity, touchEventUptime: touchTimestamp)
            }, onPressedChanged: { isPressed in
                if isPressed { heldPads.insert(sample.id) }
                else { heldPads.remove(sample.id) }
            }, haptics: haptics)
        }
        .accessibilityIdentifier("performance.pad.\(sample.id)")
    }

    @discardableResult
    private func strike(_ sample: SampleDescriptor, velocity: Float,
                        touchEventUptime: TimeInterval) -> Bool {
        let performedVelocity = min(1, max(0.05,
            velocity / 0.85 * sample.defaultVelocity))
        guard audio.triggerPad(sample.id, velocity: performedVelocity,
                               touchEventUptime: touchEventUptime) else { return false }
        // Output-latency compensation is evaluated only for a recorded hit,
        // never in the sampler's scheduling path.
        if recorder.isRecording {
            recorder.append(sample, velocity: performedVelocity,
                            sourceTime: audio.recordedPadSourceTime(),
                            rhythm: padRhythm)
        }
        exportedAudio = nil
        return true
    }

    /// User-initiated: reads bounded results after a session, never on touch.
    private var padDiagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DIAGNÓSTICO DE LATÊNCIA")
                .font(.caption.weight(.bold)).tracking(1.5)
            Text("Mede toque → envio ao motor de áudio, não o instante audível do alto-falante.")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("Cenário", selection: $latencyScenario) {
                ForEach(PadCaptureScenario.allCases) { scenario in
                    Text(scenario.rawValue).tag(scenario)
                }
            }
            .pickerStyle(.menu)
            .disabled(latencyCaptureActive)
            .accessibilityIdentifier("performance.latencyScenario")

            Button(latencyCaptureActive ? "Encerrar medição" : "Iniciar medição") {
                if latencyCaptureActive {
                    let result = audio.padLatencyProbe.finish()
                    latencyResult = result
                    if let context = activeLatencyContext {
                        let session = PadLatencyEvidenceSession(context: context, summary: result)
                        latencySessions = Array((latencySessions + [session]).suffix(6))
                    }
                    activeLatencyContext = nil
                    latencyCaptureActive = false
                } else {
                    latencyResult = nil
                    // Capture only stable route categories. Device names can
                    // contain personally identifying text, so omit them.
                    let kinds = AVAudioSession.sharedInstance().currentRoute.outputs
                        .map { $0.portType.rawValue }
                    activeLatencyContext = PadLatencyCaptureContext(
                        scenario: latencyScenario,
                        outputRouteType: kinds.isEmpty ? "unknown" : kinds.joined(separator: ","),
                        engineRunningAtStart: audio.isAudioEngineRunning,
                        musicPlayingAtStart: audio.isPlaying,
                        hapticsEnabled: haptics)
                    audio.padLatencyProbe.start()
                    latencyCaptureActive = true
                }
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("performance.latencyCapture")
            if latencyCaptureActive {
                Text("Capturando \(latencyScenario.rawValue.lowercased()). Execute 40–60 toques; inclua rolls e multitouch.")
                    .font(.caption2).foregroundStyle(accent)
            }
            if !latencySessions.isEmpty {
                HStack(spacing: 14) {
                    ShareLink(item: PadLatencyEvidenceReport.render(latencySessions),
                              subject: Text("NightcoreLab Latency Evidence")) {
                        Label("Compartilhar relatório", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("performance.latencyShare")
                    Button {
                        UIPasteboard.general.string = PadLatencyEvidenceReport.render(latencySessions)
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("performance.latencyCopy")
                }
                .font(.caption.weight(.semibold))
                Text("\(latencySessions.count) sessão(ões) coletada(s). Os valores não incluem a saída acústica.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Limpar resultados") {
                    latencySessions.removeAll()
                    latencyResult = nil
                }
                .font(.caption2)
                .disabled(latencyCaptureActive)
                .accessibilityIdentifier("performance.latencyClear")
            }
            if let result = latencyResult {
                Group {
                    Text("Disparos: \(result.accepted) • não aceitos: \(result.failed)")
                    Text("Quentes: \(result.warmCount) • frios: \(result.coldCount)")
                    if let p = result.touchDispatch {
                        Text(String(format: "Entrada UIKit → handler: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                    if let p = result.touchToCommand {
                        Text(String(format: "Toque → comando concluído: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                    if let p = result.warmCommand {
                        Text(String(format: "Comando quente: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                    if let p = result.coldCommand {
                        Text(String(format: "Comando frio: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                    if let p = result.coldEngineStart {
                        Text(String(format: "engine.start: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                    if let p = result.nodeStop {
                        Text(String(format: "node.stop: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                    if let p = result.nodeSchedule {
                        Text(String(format: "scheduleBuffer: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                    if let p = result.nodePlay {
                        Text(String(format: "node.play: p50 %.1f / p95 %.1f ms", p.p50, p.p95))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func renderPerformanceAudio() {
        guard !isRenderingAudio, audio.fileName != nil,
              recordedSourceRevision == audio.playbackSourceRevision else { return }
        let frozen = recorder.timeline(
            sourceClip: recordedClip, quantizeStrength: Float(grooveStrength))
        guard frozen.isValid && !frozen.events.isEmpty else { return }
        isRenderingAudio = true
        exportedAudio = nil
        renderError = nil
        exportTask = Task { @MainActor in
            defer { isRenderingAudio = false; exportTask = nil }
            do {
                let result = try await audio.exportPerformanceAudio(timeline: frozen)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result)
                    return
                }
                exportedAudio = result
            } catch is CancellationError {
                // The sheet was dismissed; the offline render is cancelled.
            } catch {
                renderError = error.localizedDescription
            }
        }
    }

    /// Reuses MusicIntelligenceEngine's shared scheduler/cache, off the
    /// audio callback. Revision/cancellation gates prevent stale grids.
    private func prepareMusicalGrid() {
        padRhythmTask?.cancel()
        padRhythm = nil
        guard let url = audio.visualAnalysisURL, url.isFileURL else { return }
        let revision = audio.playbackSourceRevision
        padRhythmTask = Task { @MainActor in
            do {
                let analysis = try await MusicIntelligenceEngine.shared.analysis(for: url)
                guard !Task.isCancelled,
                      revision == audio.playbackSourceRevision,
                      analysis.capabilities[.rhythm] == .available,
                      analysis.rhythmAnalyzerVersion == RhythmAnalysisResult.algorithmVersion,
                      let rhythm = analysis.rhythmAnalysis,
                      rhythm.quality == .medium || rhythm.quality == .high else { return }
                padRhythm = rhythm
            } catch { /* Unavailable rhythm keeps original timing. */ }
        }
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "kick": return "circle.circle.fill"
        case "snare": return "circle.hexagongrid.fill"
        case "closed-hat": return "circle.lefthalf.filled"
        case "open-hat": return "circle.righthalf.filled"
        case "clap": return "hands.clap.fill"
        case "crash": return "sparkles"
        case PerformanceSourceClip.slotID: return "waveform.path.ecg"
        default: return "waveform.path"
        }
    }
}
