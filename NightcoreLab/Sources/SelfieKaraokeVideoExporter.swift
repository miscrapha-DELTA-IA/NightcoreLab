import AVFoundation
import QuartzCore
import Foundation
import UIKit

/// The on-screen karaoke strip and the exported MOV use the same source-time
/// decisions. Sampling the PLAYBACK clock (not wall time × speed) also handles
/// seeks, pauses, and the user's per-route lyric offset.
struct SelfieLyricCue: Equatable, Sendable {
    let seconds: TimeInterval
    let text: String
}

enum SelfieLyricTimeline {
    static func currentText(lines: [TimedLyricLine], at sourceTime: TimeInterval) -> String {
        guard sourceTime.isFinite, let index = lines.activeIndex(at: sourceTime) else {
            return ""
        }
        let line = lines[index]
        guard sourceTime <= line.end else { return "" }
        return line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func append(_ text: String, at seconds: TimeInterval,
                       to cues: inout [SelfieLyricCue]) {
        guard seconds.isFinite, seconds >= 0, cues.count < 240 else { return }
        if let last = cues.last, last.text == text { return }
        cues.append(SelfieLyricCue(seconds: seconds, text: String(text.prefix(160))))
    }

    /// Constant cue between samples; empty text explicitly clears the subtitle.
    static func text(at seconds: TimeInterval, cues: [SelfieLyricCue]) -> String {
        guard seconds.isFinite else { return "" }
        return cues.last(where: { $0.seconds <= seconds })?.text ?? ""
    }
}

enum SelfieKaraokeVideoExporter {
    enum ExportError: LocalizedError {
        case noVideo
        case sessionUnavailable
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noVideo: return "A câmera não produziu um vídeo válido."
            case .sessionUnavailable: return "Não foi possível preparar a prévia com as letras."
            case .exportFailed: return "Falha ao criar o vídeo com karaokê. Você pode rever a gravação original."
            }
        }
    }

    /// Post-process only after camera capture finishes; preserves the original
    /// microphone audio and composes readable subtitles onto the recorded frames.
    /// No AVAudioEngine instances, audio graph changes or live video encoding taps.
    static func render(sourceURL: URL, cues: [SelfieLyricCue]) async throws -> URL {
        guard cues.contains(where: { !$0.text.isEmpty }) else { return sourceURL }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw ExportError.noVideo }
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideo
        }

        let composition = AVMutableComposition()
        guard let movie = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.noVideo
        }
        try movie.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                  of: srcVideo, at: .zero)
        if let srcAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audio = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audio.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                      of: srcAudio, at: .zero)
        }

        let naturalSize = try await srcVideo.load(.naturalSize)
        let preferredTransform = try await srcVideo.load(.preferredTransform)
        let rotatedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let videoSize = CGSize(width: abs(rotatedBounds.width), height: abs(rotatedBounds.height))
        guard videoSize.width > 0, videoSize.height > 0 else { throw ExportError.noVideo }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = videoSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: movie)
        let translation = CGAffineTransform(translationX: -rotatedBounds.minX,
                                            y: -rotatedBounds.minY)
        layerInstruction.setTransform(preferredTransform.concatenating(translation), at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let lowerThird = CALayer()
        lowerThird.frame = parentLayer.bounds
        lowerThird.isGeometryFlipped = true
        parentLayer.addSublayer(lowerThird)

        let visible = cues.enumerated().filter { !$0.element.text.isEmpty }
        let width = videoSize.width
        let fontSize = max(20, width * 0.054)
        let side = width * 0.075
        for (index, cue) in visible {
            let start = min(seconds, max(0, cue.seconds))
            let next = cues.indices.first(where: { $0 > index && cues[$0].seconds > start })
                .map { cues[$0].seconds } ?? seconds
            let end = min(seconds, max(start, next))
            guard end - start > 0.02 else { continue }

            let strip = CALayer()
            strip.frame = CGRect(x: side, y: videoSize.height * 0.68,
                                 width: width - side * 2, height: videoSize.height * 0.15)
            strip.backgroundColor = UIColor.black.withAlphaComponent(0.70).cgColor
            strip.cornerRadius = 18
            strip.masksToBounds = true
            strip.opacity = 0

            let text = CATextLayer()
            text.string = cue.text
            text.font = UIFont.systemFont(ofSize: fontSize, weight: .bold).fontName as CFString
            text.fontSize = fontSize
            text.foregroundColor = UIColor.white.cgColor
            text.alignmentMode = .center
            text.isWrapped = true
            text.contentsScale = 2
            text.frame = strip.bounds.insetBy(dx: width * 0.04, dy: videoSize.height * 0.017)
            strip.addSublayer(text)

            let times = [0.0, start / seconds, end / seconds, 1.0]
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 1, 0, 0]
            animation.keyTimes = times.map { NSNumber(value: $0) }
            animation.calculationMode = .discrete
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.duration = seconds
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
            strip.add(animation, forKey: "karaokeVisibility")
            lowerThird.addSublayer(strip)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        let output = SelfieVideoCaptureFile.temporaryURL()
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionUnavailable
        }
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: exporter.error ?? ExportError.exportFailed)
                }
            }
        }
        return output
    }
}
