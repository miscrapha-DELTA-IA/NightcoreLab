import AVFoundation
import SwiftUI

/// Temporary, local-only movie files. Nothing is uploaded by this feature.
enum SelfieVideoCaptureFile {
    static func temporaryURL(directory: URL = FileManager.default.temporaryDirectory,
                             id: UUID = UUID()) -> URL {
        directory.appendingPathComponent("GNARLY-Selfie-" + id.uuidString)
            .appendingPathExtension("mov")
    }
}

private enum SelfieCameraError: LocalizedError {
    case unavailable
    case configurationFailed
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Câmera frontal ou microfone indisponível neste iPhone."
        case .configurationFailed:
            "Não foi possível iniciar a câmera. Feche outros aplicativos que estejam usando câmera ou microfone."
        case .recordingFailed:
            "A gravação não foi concluída. Tente novamente."
        }
    }
}

/// Video and microphone capture have their own serial AVFoundation queue.
/// This is NOT another AVAudioEngine: it never changes the music player's graph,
/// transport, clock, pitch or karaoke timing.
private final class SelfieCameraPipeline: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.nightcorelab.selfie.capture", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    var didStart: (() -> Void)?
    var didFinish: ((Result<URL, Error>) -> Void)?

    func prepare(_ completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video, position: .front),
                      let microphone = AVCaptureDevice.default(for: .audio) else {
                    throw SelfieCameraError.unavailable
                }
                let cameraInput = try AVCaptureDeviceInput(device: camera)
                let micInput = try AVCaptureDeviceInput(device: microphone)

                // Respect AudioEngineManager's existing .playAndRecord session.
                // Do not allow AVCaptureSession to override category/routing.
                self.session.automaticallyConfiguresApplicationAudioSession = false
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                guard self.session.canAddInput(cameraInput),
                      self.session.canAddInput(micInput),
                      self.session.canAddOutput(self.movieOutput) else {
                    self.session.commitConfiguration()
                    throw SelfieCameraError.configurationFailed
                }
                self.session.addInput(cameraInput)
                self.session.addInput(micInput)
                self.session.addOutput(self.movieOutput)
                if let connection = self.movieOutput.connection(with: .video) {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                }
                self.session.commitConfiguration()
                self.session.startRunning()
                let ready = self.session.isRunning
                DispatchQueue.main.async {
                    completion(ready ? .success(()) : .failure(SelfieCameraError.configurationFailed))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func record(to url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning, !self.movieOutput.isRecording else {
                DispatchQueue.main.async {
                    self.didFinish?(.failure(SelfieCameraError.recordingFailed))
                }
                return
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        queue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { [weak self] in self?.didStart?() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let result: Result<URL, Error> = error.map { .failure($0) } ?? .success(outputFileURL)
        DispatchQueue.main.async { [weak self] in self?.didFinish?(result) }
    }
}

@MainActor
final class SelfieVideoRecorder: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var recordedURL: URL?
    @Published var errorText: String?
    @Published private(set) var wasSaved = false
    @Published private(set) var isSaving = false

    private let pipeline = SelfieCameraPipeline()
    private var closed = false
    private var pendingURL: URL?

    var session: AVCaptureSession { pipeline.session }

    init() {
        pipeline.didStart = { [weak self] in
            self?.isRecording = true
            self?.isFinishing = false
        }
        pipeline.didFinish = { [weak self] result in
            guard let self else { return }
            self.isRecording = false
            self.isFinishing = false
            switch result {
            case .success(let url):
                if self.closed {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    self.recordedURL = url
                }
            case .failure(let error):
                if !self.closed { self.errorText = error.localizedDescription }
                if let url = self.pendingURL { try? FileManager.default.removeItem(at: url) }
            }
            self.pendingURL = nil
        }
    }

    func prepare() async {
        guard !closed, !isReady else { return }
        guard await Self.authorize(.video) else {
            errorText = "Autorize a câmera para gravar seu vídeo em Ajustes → GNARLY."
            return
        }
        guard await Self.authorize(.audio) else {
            errorText = "Autorize o microfone para gravar sua voz em Ajustes → GNARLY."
            return
        }
        guard !closed else { return }
        pipeline.prepare { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success: self.isReady = true
            case .failure(let error): self.errorText = error.localizedDescription
            }
        }
    }

    private static func authorize(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    func start() {
        guard isReady, !isRecording, !isFinishing, recordedURL == nil else { return }
        errorText = nil
        let url = SelfieVideoCaptureFile.temporaryURL()
        pendingURL = url
        isFinishing = true
        pipeline.record(to: url)
    }

    func stop() {
        guard isRecording else { return }
        isFinishing = true
        pipeline.stopRecording()
    }

    func save() async {
        guard let url = recordedURL, !wasSaved, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await StoryPhotoLibrary.save(url)
            wasSaved = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    func retake() {
        guard !isRecording, !isFinishing else { return }
        if let recordedURL { try? FileManager.default.removeItem(at: recordedURL) }
        recordedURL = nil
        wasSaved = false
        errorText = nil
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        pipeline.shutdown()
        if let recordedURL { try? FileManager.default.removeItem(at: recordedURL) }
        recordedURL = nil
    }
}

private final class SelfieCameraPreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct SelfieCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> SelfieCameraPreviewSurface {
        let view = SelfieCameraPreviewSurface()
        view.backgroundColor = .black
        view.videoLayer.videoGravity = .resizeAspectFill
        view.videoLayer.session = session
        if let connection = view.videoLayer.connection,
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return view
    }

    func updateUIView(_ view: SelfieCameraPreviewSurface, context: Context) {}
}

/// Small, opt-in selfie take. Its only retained output is a local .mov until
/// the user explicitly saves to Photos or shares it.
struct SelfieRecordingView: View {
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = SelfieVideoRecorder()
    @State private var confirmDiscard = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SelfieCameraPreview(session: recorder.session)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            LinearGradient(colors: [.black.opacity(0.75), .clear, .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 18) {
                HStack {
                    Button {
                        if recorder.isRecording || recorder.isFinishing ||
                           (recorder.recordedURL != nil && !recorder.wasSaved) {
                            confirmDiscard = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Fechar câmera")
                    Spacer()
                    Label(recorder.isRecording ? "GRAVANDO" : "GNARLY · CÂMERA",
                          systemImage: recorder.isRecording ? "record.circle.fill" : "camera.fill")
                        .font(.caption.bold()).tracking(1.2)
                        .foregroundStyle(recorder.isRecording ? .red : accent)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer()

                if let errorText = recorder.errorText {
                    Text(errorText)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("selfie.error")
                }

                if let recordedURL = recorder.recordedURL {
                    Text(recorder.wasSaved ? "Vídeo salvo em Fotos" : "Seu vídeo está pronto")
                        .font(.headline)
                    HStack(spacing: 14) {
                        Button("Gravar novamente") { recorder.retake() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .disabled(recorder.isSaving)
                        Button {
                            Task { await recorder.save() }
                        } label: {
                            Label(recorder.wasSaved ? "Salvo em Fotos" :
                                    (recorder.isSaving ? "Salvando…" : "Salvar em Fotos"),
                                  systemImage: recorder.wasSaved ?
                                    "checkmark.circle.fill" : "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .disabled(recorder.isSaving || recorder.wasSaved)
                    }
                    ShareLink(item: recordedURL, preview: SharePreview("Meu vídeo GNARLY")) {
                        Label("Compartilhar arquivo de vídeo", systemImage: "square.and.arrow.up")
                            .font(.caption.bold())
                    }
                    .padding(.top, 6)
                } else {
                    Text("Vídeo selfie + sua voz")
                        .font(.headline)
                    Text("A câmera grava a voz do microfone. A trilha não é mixada no arquivo; use o alto-falante se quiser captá-la junto.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 330)

                    Button {
                        if recorder.isRecording { recorder.stop() }
                        else { recorder.start() }
                    } label: {
                        ZStack {
                            Circle().strokeBorder(accent, lineWidth: 3)
                                .frame(width: 76, height: 76)
                            if recorder.isRecording {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(.red)
                                    .frame(width: 26, height: 26)
                            } else {
                                Circle().fill(.red).frame(width: 52, height: 52)
                            }
                        }
                        .frame(width: 84, height: 84)
                    }
                    .buttonStyle(.plain)
                    .disabled(!recorder.isReady || recorder.isFinishing)
                    .accessibilityLabel(recorder.isRecording ? "Parar gravação" : "Iniciar gravação")
                    .accessibilityIdentifier("selfie.recordToggle")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
        .task { await recorder.prepare() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.stop() }
        }
        .onDisappear { recorder.shutdown() }
        .confirmationDialog("Descartar a gravação?", isPresented: $confirmDiscard) {
            Button("Descartar e fechar", role: .destructive) { dismiss() }
            Button("Continuar", role: .cancel) {}
        } message: {
            Text("Se você ainda não salvou em Fotos, o arquivo será descartado.")
        }
        .accessibilityIdentifier("selfie.captureScreen")
    }
}
