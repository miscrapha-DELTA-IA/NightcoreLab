// Adapted from demucs-coreml-ios, MIT, Copyright (c) 2026 Nikolai Tsyrenov.
import Accelerate
import Foundation

/// Chunking helpers for running the fixed-size htdemucs core over a whole song.
///
/// The exported core only accepts one 7.8 s segment, so a track is cut into overlapping chunks,
/// each chunk is separated independently, and the results are cross-faded back together with
/// triangular weights — the same scheme as `demucs.apply.apply_model`.
public enum OverlapAdd {

    /// The same dense triangular overlap as Demucs, with no extra song-sized
    /// scratch. Accelerate processes contiguous lanes instead of visiting
    /// every source inside a scalar per-sample Swift loop.
    static func accumulate(_ separated: [Float], weight: [Float],
                           accumulator: inout [Float], weights: inout [Float]) {
        let length = weight.count
        precondition(length > 0 && separated.count.isMultiple(of: length))
        precondition(accumulator.count == separated.count && weights.count == length)
        separated.withUnsafeBufferPointer { source in
            weight.withUnsafeBufferPointer { window in
                accumulator.withUnsafeMutableBufferPointer { target in
                    for lane in 0..<(separated.count / length) {
                        let offset = lane * length
                        vDSP_vma(source.baseAddress! + offset, 1, window.baseAddress!, 1,
                                 target.baseAddress! + offset, 1, target.baseAddress! + offset, 1,
                                 vDSP_Length(length))
                    }
                }
                weights.withUnsafeMutableBufferPointer { total in
                    vDSP_vadd(total.baseAddress!, 1, window.baseAddress!, 1,
                              total.baseAddress!, 1, vDSP_Length(length))
                }
            }
        }
    }

    /// Every emitted frame is covered by a strictly positive triangular
    /// window. Restore its original whole-mix normalisation independently in
    /// each source, retaining float32 output and the original DC split.
    static func restoreLane(_ accumulated: UnsafePointer<Float>, weights: UnsafePointer<Float>,
                            count: Int, standardDeviation: Float, mean: Float,
                            to output: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        var scale = standardDeviation, bias = mean / 4
        vDSP_vdiv(weights, 1, accumulated, 1, output, 1, vDSP_Length(count))
        vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(count))
        vDSP_vsadd(output, 1, &bias, output, 1, vDSP_Length(count))
    }

    /// Shift an overlap window in-place, preserving its exact float32 values.
    /// Array.removeFirst + append can allocate and repeatedly rebuild the
    /// 344k-float weight buffer for every segment of a long track.
    /// This mirrors the fixed-size 8-lane PCM accumulator's existing shift.
    static func advanceWeights(_ weights: inout [Float], by amount: Int) {
        precondition(amount >= 0 && amount <= weights.count)
        guard amount > 0 else { return }
        weights.withUnsafeMutableBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            let remaining = buffer.count - amount
            if remaining > 0 {
                memmove(pointer, pointer + amount, remaining * MemoryLayout<Float>.stride)
            }
            (pointer + remaining).update(repeating: 0, count: amount)
        }
    }

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
