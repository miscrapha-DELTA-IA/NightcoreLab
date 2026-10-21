import Accelerate
import Foundation

/// Exact dense attention with GLOBAL keys/values. Only query rows are tiled,
/// so scores occupy at most blockRows * keys floats, not heads * queries * keys.
/// Stereo branches and heads execute serially; no sparse/window approximation.
public enum BlockedAttention {
    public static let blockRows = 64

    public static func evaluate(query: [Float], key: [Float], value: [Float],
                                heads: Int, queries: Int, keys: Int, width: Int,
                                check: () throws -> Void = {}) throws -> [Float] {
        guard heads > 0, queries > 0, keys > 0, width > 0,
              query.count == heads * queries * width,
              key.count == heads * keys * width, value.count == key.count else {
            throw NeuralStemError.invalidOutput
        }
        var output = [Float](repeating: 0, count: query.count)
        var scores = [Float](repeating: 0, count: min(blockRows, queries) * keys)
        let scale = Float(1 / sqrt(Double(width)))
        try query.withUnsafeBufferPointer { q in
            try key.withUnsafeBufferPointer { k in
                try value.withUnsafeBufferPointer { v in
                    try output.withUnsafeMutableBufferPointer { out in
                        try scores.withUnsafeMutableBufferPointer { scratch in
                            for head in 0..<heads {
                                for start in stride(from: 0, to: queries, by: blockRows) {
                                    try check()
                                    let rows = min(blockRows, queries - start)
                                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                                Int32(rows), Int32(keys), Int32(width), scale,
                                                q.baseAddress! + (head * queries + start) * width, Int32(width),
                                                k.baseAddress! + head * keys * width, Int32(width),
                                                0, scratch.baseAddress!, Int32(keys))
                                    for row in 0..<rows {
                                        let values = scratch.baseAddress! + row * keys
                                        var maximum: Float = 0, count = Int32(keys)
                                        vDSP_maxv(values, 1, &maximum, vDSP_Length(keys))
                                        maximum = -maximum
                                        vDSP_vsadd(values, 1, &maximum, values, 1, vDSP_Length(keys))
                                        vvexpf(values, values, &count)
                                        var total: Float = 0
                                        vDSP_sve(values, 1, &total, vDSP_Length(keys))
                                        guard total.isFinite, total > 0 else { throw NeuralStemError.invalidOutput }
                                        vDSP_vsdiv(values, 1, &total, values, 1, vDSP_Length(keys))
                                    }
                                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                                                Int32(rows), Int32(width), Int32(keys), 1,
                                                scratch.baseAddress!, Int32(keys),
                                                v.baseAddress! + head * keys * width, Int32(width),
                                                0, out.baseAddress! + (head * queries + start) * width, Int32(width))
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }
}
