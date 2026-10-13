import AVFoundation
import Foundation
import UIKit

/// A set of existing file URLs, NOT a ZIP or new exporter.
struct SharePackage: Identifiable {
    let id = UUID()
    let videoURL: URL
    let thumbnailURL: URL
    let metadataURL: URL
    let exportProfile: ExportProfile
    let metadata: ShareMetadata

    var files: [URL] { [videoURL, thumbnailURL, metadataURL] }
}

struct ShareMetadata: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let title: String
    let artist: String
    let presetID: String
    let materialID: String
    let duration: Double
    let width: Int
    let height: Int
    let fps: Int32
    let codec: String
    let quality: ExportQuality
    let aspectRatio: ExportAspectRatio
    let cropPolicy: ExportCropPolicy
    let thumbnailFrameIndex: Int
    let thumbnailElapsed: Double
    let exportedAt: Date
}

enum SharePackageError: LocalizedError {
    case invalidVideo, invalidThumbnail
    var errorDescription: String? {
        switch self {
        case .invalidVideo: return "O arquivo de vídeo exportado não passou pela verificação."
        case .invalidThumbnail: return "A imagem de capa do compartilhamento não foi gerada."
        }
    }
}

/// Product orchestration ABOVE the stable StoryVideoExporter.
@MainActor
enum SharePackageBuilder {
    static func build(
        request: StoryVideoRequest,
        audioSource: StoryAudioSource?,
        artwork: UIImage?,
        selectedProfile: ExportProfile,
        visualTimeline: AudioFeatureTimeline?,
        visualRhythm: RhythmAnalysisResult?,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> SharePackage {
        let encoding = selectedProfile.encodingProfile(for: request.mode)
        let timeline = StoryRenderTimeline(request: request, profile: encoding)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightcoreShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        var exportedVideo: URL?
        do {
            let video = try await StoryVideoExporter.export(
                request, audioSource: audioSource, artwork: artwork,
                profile: encoding, visualTimeline: visualTimeline,
                visualRhythm: visualRhythm,
                progress: { progress($0 * 0.94) })
            exportedVideo = video
            try Task.checkCancellation()

            // Validate the ACTUAL encoded MP4, not only the selected profile.
            let asset = AVURLAsset(url: video)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else { throw SharePackageError.invalidVideo }
            let size = try await videoTrack.load(.naturalSize)
            let videoDuration = try await asset.load(.duration)
            guard Int(size.width.rounded()) == encoding.width,
                  Int(size.height.rounded()) == encoding.height,
                  CMTimeGetSeconds(videoDuration).isFinite,
                  CMTimeGetSeconds(videoDuration) > 0 else {
                throw SharePackageError.invalidVideo
            }
            if request.includeAudio {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard !audioTracks.isEmpty else { throw SharePackageError.invalidVideo }
            }
            try Task.checkCancellation()

            // Same frame-grid and same StoryFrameRenderer as the MP4.
            // Frame zero avoids changing identity with duration or audio peaks.
            let thumbIndex = 0
            let thumbFrame = timeline.frame(index: thumbIndex)
            let pixels = try StoryFrameRenderer.render(
                request: request, artwork: artwork, frame: thumbFrame,
                profile: encoding, visualTimeline: visualTimeline,
                visualRhythm: visualRhythm)
            guard let bytes = UIImage(cgImage: pixels).jpegData(compressionQuality: 0.91) else {
                throw SharePackageError.invalidThumbnail
            }
            let thumbnailURL = folder.appendingPathComponent("thumbnail.jpg")
            try bytes.write(to: thumbnailURL, options: .atomic)
            progress(0.97)
            try Task.checkCancellation()

            let metadata = ShareMetadata(
                schemaVersion: ShareMetadata.currentSchemaVersion,
                title: request.title, artist: request.artist,
                presetID: request.renderRuntime?.composition.program.id ??
                    request.reactiveProgram?.id ?? CreativePresetCatalog.defaultID,
                materialID: request.renderRuntime?.material.id ?? VisualMaterial.legacyMarble.id,
                duration: request.duration,
                width: encoding.width, height: encoding.height, fps: encoding.fps,
                codec: "h264", quality: selectedProfile.quality,
                aspectRatio: selectedProfile.aspectRatio,
                cropPolicy: encoding.cropPolicy,
                thumbnailFrameIndex: thumbIndex,
                thumbnailElapsed: thumbFrame.elapsed,
                exportedAt: Date())
            let metadataURL = folder.appendingPathComponent("metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
            try Task.checkCancellation()

            let destination = folder.appendingPathComponent("video.mp4")
            try FileManager.default.moveItem(at: video, to: destination)
            exportedVideo = nil
            progress(1)
            return SharePackage(videoURL: destination,
                                thumbnailURL: thumbnailURL,
                                metadataURL: metadataURL,
                                exportProfile: selectedProfile,
                                metadata: metadata)
        } catch {
            if let exportedVideo { try? FileManager.default.removeItem(at: exportedVideo) }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
