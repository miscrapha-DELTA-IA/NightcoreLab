import AVFoundation
import CoreGraphics
import CoreVideo
import SwiftUI
import UIKit

enum StoryVideoError: LocalizedError {
    case renderFailed, invalidPixelBuffer, writerFailed, missingTrack, muxFailed
    var errorDescription: String? {
        switch self {
        case .renderFailed: return "Não foi possível desenhar o Story."
        case .invalidPixelBuffer: return "Não foi possível preparar os quadros do vídeo."
        case .writerFailed: return "Não foi possível codificar o MP4."
        case .missingTrack: return "O vídeo ou o áudio exportado está incompleto."
        case .muxFailed: return "Não foi possível sincronizar o áudio com o vídeo."
        }
    }
}

/// Sequential frame writer: never holds 450 full-size images in memory.
/// Isolated to the main actor because ImageRenderer requires SwiftUI main-actor rendering.
@MainActor
enum StoryVideoExporter {
    static func export(_ request: StoryVideoRequest, audioSource: StoryAudioSource?,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let image = await ShareRenderer.loadArtwork(request.artworkURL)
        try Task.checkCancellation()

        var audioURL: URL?
        if request.includeAudio {
            guard let audioSource else { throw AudioEngineError.noFileLoaded }
            progress(0.02)
            audioURL = try await AudioEngineManager.exportStorySegment(
                source: audioSource, startTime: request.playbackTime,
                duration: request.duration)
        }
        defer { if let audioURL { try? FileManager.default.removeItem(at: audioURL) } }
        progress(0.12)

        let silentURL = try await renderVideo(request, artwork: image) { fraction in
            progress(0.12 + fraction * 0.78)
        }
        guard let audioURL else {
            progress(1)
            return silentURL
        }
        do {
            try Task.checkCancellation()
            let combined = try await mixAudio(videoURL: silentURL, audioURL: audioURL)
            try? FileManager.default.removeItem(at: silentURL)
            progress(1)
            return combined
        } catch {
            try? FileManager.default.removeItem(at: silentURL)
            throw error
        }
    }

    private static func renderVideo(
        _ request: StoryVideoRequest, artwork: UIImage?,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightcoreStory-\(UUID().uuidString).mp4")
        let width = 1080, height = 1920
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw StoryVideoError.writerFailed }
        writer.add(videoInput)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
        guard writer.startWriting() else {
            throw writer.error ?? StoryVideoError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
        do {
            for index in 0..<request.frameCount {
                try Task.checkCancellation()
                let seconds = Double(index) / Double(StoryVideoRequest.fps)
                let frame = StorySceneView(request: request, artwork: artwork, elapsed: seconds)
                let renderer = ImageRenderer(content: frame)
                renderer.proposedSize = ProposedViewSize(StoryVideoRequest.size)
                renderer.scale = 2
                guard let cgImage = renderer.uiImage?.cgImage else {
                    throw StoryVideoError.renderFailed
                }
                guard let pool = adapter.pixelBufferPool else {
                    throw StoryVideoError.invalidPixelBuffer
                }
                var maybeBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer)
                        == kCVReturnSuccess, let buffer = maybeBuffer else {
                    throw StoryVideoError.invalidPixelBuffer
                }
                try draw(cgImage, into: buffer, width: width, height: height)
                while !videoInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed {
                        throw writer.error ?? StoryVideoError.writerFailed
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let time = CMTime(value: CMTimeValue(index), timescale: StoryVideoRequest.fps)
                guard adapter.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? StoryVideoError.writerFailed
                }
                if index.isMultiple(of: 5) {
                    onProgress(Double(index + 1) / Double(request.frameCount))
                }
                await Task.yield()
            }
            videoInput.markAsFinished()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume(returning: ()) }
                    else { continuation.resume(throwing: writer.error ?? StoryVideoError.writerFailed) }
                }
            }
            try Task.checkCancellation()
            return url
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer,
                             width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let bytes = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
              ) else { throw StoryVideoError.invalidPixelBuffer }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func mixAudio(videoURL: URL, audioURL: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw StoryVideoError.missingTrack
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw StoryVideoError.muxFailed }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                  of: videoTrack, at: .zero)
        video.preferredTransform = try await videoTrack.load(.preferredTransform)
        try audio.insertTimeRange(CMTimeRange(
            start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)),
            of: audioTrack, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition,
                presetName: AVAssetExportPresetPassthrough) else {
            throw StoryVideoError.muxFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightcoreStory-Audio-\(UUID().uuidString).mp4")
        exporter.outputURL = url
        exporter.outputFileType = .mp4
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    if exporter.status == .completed { continuation.resume(returning: ()) }
                    else { continuation.resume(throwing: exporter.error ?? StoryVideoError.muxFailed) }
                }
            }
            try Task.checkCancellation()
            return url
        } catch {
            exporter.cancelExport()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
