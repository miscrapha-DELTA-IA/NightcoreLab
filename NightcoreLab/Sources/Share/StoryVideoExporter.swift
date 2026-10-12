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

/// Lower pixel count, one shader/frame and a worker-owned encoder.  The fast
/// profile is vertical 720p/20fps; Low Power Mode uses 540p/15fps.
struct StoryEncodingProfile: Sendable {
    let width: Int
    let height: Int
    let fps: Int32
    let bitRate: Int
    var scale: CGFloat { CGFloat(width) / StoryVideoRequest.size.width }
    func frameCount(duration: TimeInterval) -> Int {
        max(1, Int(ceil(duration * Double(fps))))
    }
    static let balanced = StoryEncodingProfile(width: 720, height: 1280,
                                                fps: 20, bitRate: 2_800_000)
    static let economical = StoryEncodingProfile(width: 540, height: 960,
                                                  fps: 15, bitRate: 1_600_000)
    static func recommended() -> Self {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? .economical : .balanced
    }
}

/// Writes pixels/encodes *away* from MainActor. One in-flight frame only.
private actor StoryPixelWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adapter: AVAssetWriterInputPixelBufferAdaptor
    private let profile: StoryEncodingProfile

    init(url: URL, profile: StoryEncodingProfile) throws {
        self.profile = profile
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: profile.width,
            AVVideoHeightKey: profile.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: profile.bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(profile.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(profile.fps)
            ]
        ])
        input.expectsMediaDataInRealTime = false
        // Pixel buffers carry upright portrait content; do not rotate in metadata.
        input.transform = .identity
        guard writer.canAdd(input) else { throw StoryVideoError.writerFailed }
        writer.add(input)
        adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: profile.width,
                kCVPixelBufferHeightKey as String: profile.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
    }

    func start() throws {
        guard writer.startWriting() else {
            throw writer.error ?? StoryVideoError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, at index: Int) async throws {
        try Task.checkCancellation()
        guard let pool = adapter.pixelBufferPool else {
            throw StoryVideoError.invalidPixelBuffer
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                == kCVReturnSuccess, let buffer else {
            throw StoryVideoError.invalidPixelBuffer
        }
        try Self.paint(image: image, into: buffer,
                       width: profile.width, height: profile.height)
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed {
                throw writer.error ?? StoryVideoError.writerFailed
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        let time = CMTime(value: CMTimeValue(index), timescale: profile.fps)
        guard adapter.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? StoryVideoError.writerFailed
        }
    }

    func finish() async throws {
        input.markAsFinished()
        let assetWriter = writer
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            assetWriter.finishWriting {
                if assetWriter.status == .completed {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: assetWriter.error ?? StoryVideoError.writerFailed)
                }
            }
        }
    }

    func cancel() { writer.cancelWriting() }

    /// Bitmap memory is row-major; its first row is written directly to the
    /// first row of the video frame. Avoid the previous extra Y inversion.
    static func paint(image: CGImage, into buffer: CVPixelBuffer,
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
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

@MainActor
enum StoryVideoExporter {
    static func export(_ request: StoryVideoRequest, audioSource: StoryAudioSource?,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let image = await ShareRenderer.loadArtwork(request.artworkURL)
        try Task.checkCancellation()
        return try await export(request, audioSource: audioSource, artwork: image,
                                profile: .recommended(), progress: progress)
    }

    /// The draft preview supplies its already-loaded cover and frozen encoding
    /// profile. Do not fetch artwork again or change FPS after preview approval.
    static func export(_ request: StoryVideoRequest, audioSource: StoryAudioSource?,
                       artwork: UIImage?, profile: StoryEncodingProfile,
                       visualTimeline: AudioFeatureTimeline? = nil,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
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
        let videoURL = try await renderVideo(
            request, artwork: artwork, profile: profile,
            visualTimeline: visualTimeline
        ) {
            progress(0.12 + 0.78 * $0)
        }
        guard let audioURL else {
            progress(1)
            return videoURL
        }
        do {
            try Task.checkCancellation()
            let combined = try await mixAudio(videoURL: videoURL, audioURL: audioURL)
            try? FileManager.default.removeItem(at: videoURL)
            progress(1)
            return combined
        } catch {
            try? FileManager.default.removeItem(at: videoURL)
            throw error
        }
    }

    private static func renderVideo(
        _ request: StoryVideoRequest, artwork: UIImage?,
        profile: StoryEncodingProfile,
        visualTimeline: AudioFeatureTimeline?,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let timeline = StoryRenderTimeline(request: request, profile: profile)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightcoreStory-\(UUID().uuidString).mp4")
        let encoder = try StoryPixelWriter(url: url, profile: profile)
        try await encoder.start()
        let count = timeline.frameCount
        do {
            for index in 0..<count {
                try Task.checkCancellation()
                let frame = timeline.frame(index: index)
                // One timestamp-derived scene for the scrub preview, single
                // frame captures, and MP4. Encoding stays on the worker actor.
                let cgImage: CGImage = try autoreleasepool {
                    try StoryFrameRenderer.render(
                        request: request, artwork: artwork,
                        frame: frame, profile: profile,
                        visualTimeline: visualTimeline
                    )
                }
                try await encoder.append(cgImage, at: index)
                if index.isMultiple(of: 4) {
                    onProgress(Double(index + 1) / Double(count))
                }
                // Reserve main-thread time for player, scrolling and cancel taps.
                try await Task.sleep(for: .milliseconds(15))
            }
            try await encoder.finish()
            try Task.checkCancellation()
            return url
        } catch {
            await encoder.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// In tests, encode a tiny orientation chart through the SAME code path.
    static func encodeOrientationProbe(_ image: CGImage) async throws -> URL {
        let profile = StoryEncodingProfile(width: image.width, height: image.height,
                                           fps: 1, bitRate: 500_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightcoreOrientation-\(UUID().uuidString).mp4")
        let encoder = try StoryPixelWriter(url: url, profile: profile)
        try await encoder.start()
        do {
            try await encoder.append(image, at: 0)
            try await encoder.finish()
            return url
        } catch {
            await encoder.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
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
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    if exporter.status == .completed { cont.resume(returning: ()) }
                    else { cont.resume(throwing: exporter.error ?? StoryVideoError.muxFailed) }
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
