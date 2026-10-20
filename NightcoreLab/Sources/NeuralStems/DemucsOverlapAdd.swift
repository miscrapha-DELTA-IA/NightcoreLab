// Adapted from demucs-coreml-ios, MIT, Copyright (c) 2026 Nikolai Tsyrenov.
import Foundation

/// Chunking helpers for running the fixed-size htdemucs core over a whole song.
///
/// The exported core only accepts one 7.8 s segment, so a track is cut into overlapping chunks,
/// each chunk is separated independently, and the results are cross-faded back together with
/// triangular weights — the same scheme as `demucs.apply.apply_model`.
public enum OverlapAdd {

    /// Default overlap between neighbouring chunks (demucs uses 0.25; 0.5 costs 2× time for a
    /// small quality gain — see docs/GOTCHAS.md).
    public static let defaultOverlap = 0.25

    /// Distance between chunk starts, in samples.
    public static func stride(segment: Int = StemDSP.segmentSamples,
                              overlap: Double = defaultOverlap) -> Int {
        Int(Double(segment) * (1 - overlap))
    }

    /// Start offsets of every chunk covering `totalSamples`.
    public static func offsets(totalSamples: Int,
                               segment: Int = StemDSP.segmentSamples,
                               overlap: Double = defaultOverlap) -> [Int] {
        guard totalSamples > 0 else { return [] }
        return Swift.stride(from: 0, to: totalSamples, by: stride(segment: segment, overlap: overlap)).map { $0 }
    }

    /// Triangular cross-fade weights, peaking in the middle of the chunk and normalised to 1.
    /// Sum the weighted chunks and divide by the summed weights to reconstruct the track.
    public static func triangleWeights(_ length: Int) -> [Float] {
        let half = length / 2
        var w = [Float]()
        w.reserveCapacity(length)
        for i in 1...half { w.append(Float(i)) }
        for i in Swift.stride(from: length - half, through: 1, by: -1) { w.append(Float(i)) }
        let m = w.max() ?? 1
        return w.map { $0 / m }
    }
}
