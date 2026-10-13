import AVKit
import Photos
import SwiftUI

struct StoryVideoPayload: Identifiable {
    let id = UUID()
    let url: URL
    let package: SharePackage?

    init(url: URL) { self.url = url; self.package = nil }
    init(package: SharePackage) {
        self.url = package.videoURL
        self.package = package
    }
}

enum StoryPhotoError: LocalizedError {
    case permissionDenied
    var errorDescription: String? {
        "Para salvar o Story, permita adicionar vídeos ao app Fotos nos Ajustes do iPhone."
    }
}

enum StoryPhotoLibrary {
    /// YouTube may not accept MP4 URLs directly from the generic iOS share sheet.
    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw StoryPhotoError.permissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

struct StoryVideoPreview: View {
    let url: URL
    var package: SharePackage? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isSaving = false
    @State private var savedToPhotos = false
    @State private var showSavedAlert = false
    @State private var photoError: String?
    @State private var isShowingSaveError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(package.map {
                            CGFloat($0.metadata.width) / CGFloat($0.metadata.height)
                        } ?? 9.0 / 16.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        do {
                            try await StoryPhotoLibrary.save(url)
                            savedToPhotos = true
                            showSavedAlert = true
                        } catch {
                            photoError = error.localizedDescription
                            isShowingSaveError = true
                        }
                    }
                } label: {
                    Label(isSaving ? "Salvando..." :
                          (savedToPhotos ? "Salvo em Fotos" : "Salvar em Fotos · Shorts"),
                          systemImage: savedToPhotos ? "checkmark.circle" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isSaving || savedToPhotos)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                ShareLink(item: url, preview: SharePreview("NightcoreLab Story")) {
                    Label("Compartilhar arquivo MP4", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if let package {
                    HStack(spacing: 10) {
                        ShareLink(item: package.thumbnailURL) {
                            Label("Thumbnail", systemImage: "photo")
                                .frame(maxWidth: .infinity)
                        }
                        ShareLink(item: package.metadataURL) {
                            Label("Metadados", systemImage: "doc.text")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)

                    ShareLink(items: package.files) {
                        Label("Compartilhar pacote · 3 arquivos",
                              systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text("Para salvar em Arquivos, abra Compartilhar pacote e escolha Salvar em Arquivos.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("YouTube Shorts: salve em Fotos, abra YouTube, toque em +, envie um vídeo e selecione o Story.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Seu Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear {
                let prepared = AVPlayer(url: url)
                player = prepared
                prepared.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .alert("Salvo em Fotos", isPresented: $showSavedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("O vídeo está na galeria. Abra o YouTube e importe como Short.")
            }
            .alert("Não foi possível salvar", isPresented: $isShowingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(photoError ?? "Verifique o acesso ao app Fotos.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
