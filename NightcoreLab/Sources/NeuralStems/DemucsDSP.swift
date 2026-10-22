// Adapted from demucs-coreml-ios, MIT, Copyright (c) 2026 Nikolai Tsyrenov.
import Accelerate
import Foundation

/// The half of htdemucs that Core ML cannot run: the STFT/iSTFT wrapper.
///
/// Core ML has no FFT and no complex tensors, so `_spec`/`_ispec`/`_mask` are lifted out of the
/// model (see `convert/convert_core.py`) and reimplemented here on Accelerate/vDSP. This is a
/// line-by-line port of `convert/stemcommon.py`, which itself mirrors `demucs.htdemucs`:
/// hann 4096 periodic, hop 1024, `normalized=True`, reflect padding, frame slice `[2:2+le]`,
/// Nyquist bin dropped. Parity with PyTorch is pinned by golden tests.
///
/// Every size is fixed: the exported core takes exactly one 7.8 s segment (343 980 samples)
/// of 44.1 kHz stereo. Feed it chunk by chunk (see `OverlapAdd`).
public enum StemDSP {

    public static let nFFT = 4096
    public static let hop = 1024
    public static let segmentSamples = 343_980       // 7.8 s * 44100, htdemucs training segment
    public static let frames = 336                   // ceil(343980 / 1024)
    public static let bins = 2048                    // nFFT/2, Nyquist dropped
    /// `demucs.pad1d`: hop/2*3 on the left, right pad rounds up to le*hop.
    public static let padLeft = 1536
    public static let padRight = 1620
    public static let paddedLength = 347_136         // 336*1024 + 3072

    /// `torch.stft(normalized=True)` is the mathematical DFT / sqrt(nFFT); vDSP's real FFT
    /// returns 2 * mathematical DFT, hence /128 (= 2 * sqrt(4096)).
    private static let forwardScale: Float = 1.0 / 128.0
    /// Inverse: vDSP gives nFFT * irfft, torch's `ispectro` multiplies by sqrt(nFFT) → /64.
    private static let inverseScale: Float = 1.0 / 64.0
    /// Overlap-add envelope of hann² at hop = N/4.
    private static let olaEnvelope: Float = 1.5

    private static let window: [Float] = {
        // hann periodic (torch default): 0.5*(1-cos(2πn/N))
        (0..<nFFT).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(nFFT))) }
    }()

    // FFTSetup is immutable once created and safe to read from several threads.
    nonisolated(unsafe) private static let fftSetup: FFTSetup =
        vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!

    /// Reflect padding as in `demucs.pad1d` — the edge sample is not repeated.
    public static func padReflect(_ x: [Float]) -> [Float] {
        precondition(x.count == segmentSamples)
        var out = [Float](repeating: 0, count: paddedLength)
        for i in 0..<padLeft { out[i] = x[padLeft - i] }
        out.replaceSubrange(padLeft..<(padLeft + x.count), with: x)
        for i in 0..<padRight { out[padLeft + x.count + i] = x[x.count - 2 - i] }
        return out
    }

    /// STFT of one channel: (343980,) → re/im laid out as [bin][frame], matching the
    /// model tensor axis order (…, 2048, 336).
    public static func stft(_ x: [Float]) -> (re: [Float], im: [Float]) {
        let padded = padReflect(x)
        var re = [Float](repeating: 0, count: bins * frames)
        var im = [Float](repeating: 0, count: bins * frames)

        var frameRe = [Float](repeating: 0, count: nFFT / 2)
        var frameIm = [Float](repeating: 0, count: nFFT / 2)
        var windowed = [Float](repeating: 0, count: nFFT)
        var scale = forwardScale

        re.withUnsafeMutableBufferPointer { real in
            im.withUnsafeMutableBufferPointer { imaginary in
                for f in 0..<frames {
                    let start = f * hop
                    padded.withUnsafeBufferPointer { p in
                        vDSP_vmul(p.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(nFFT))
                    }
                    frameRe.withUnsafeMutableBufferPointer { rp in
                        frameIm.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            windowed.withUnsafeBytes { wb in
                                vDSP_ctoz(wb.baseAddress!.assumingMemoryBound(to: DSPComplex.self),
                                          2, &split, 1, vDSP_Length(nFFT / 2))
                            }
                            vDSP_fft_zrip(fftSetup, &split, 1, 12, FFTDirection(FFT_FORWARD))
                            // Packed format: realp[0] = DC, imagp[0] = Nyquist (which htdemucs drops).
                            real[f] = rp[0] * forwardScale
                            imaginary[f] = 0
                            // Write directly to [bin,frame] with an output stride;
                            // no full-size transposed scratch and no scalar bin loop.
                            vDSP_vsmul(rp.baseAddress! + 1, 1, &scale,
                                       real.baseAddress! + frames + f, vDSP_Stride(frames), vDSP_Length(bins - 1))
                            vDSP_vsmul(ip.baseAddress! + 1, 1, &scale,
                                       imaginary.baseAddress! + frames + f, vDSP_Stride(frames), vDSP_Length(bins - 1))
                        }
                    }
                }
            }
        }
        return (re, im)
    }

    /// iSTFT of one channel: re/im (bins, frames) → (343980,).
    /// Mirrors `ispectro`: Nyquist = 0, two empty frames padded on each side, overlap-add, crop.
    public static func istft(re: [Float], im: [Float]) -> [Float] {
        precondition(re.count == bins * frames && im.count == bins * frames)
        let totalFrames = frames + 4                      // F.pad(z, (2, 2))
        let olaLength = (totalFrames - 1) * hop + nFFT
        var ola = [Float](repeating: 0, count: olaLength)

        var specRe = [Float](repeating: 0, count: nFFT / 2)
        var specIm = [Float](repeating: 0, count: nFFT / 2)
        var frame = [Float](repeating: 0, count: nFFT)

        re.withUnsafeBufferPointer { real in
            im.withUnsafeBufferPointer { imaginary in
                for f in 0..<frames {
                    specRe.withUnsafeMutableBufferPointer { rp in
                        specIm.withUnsafeMutableBufferPointer { ip in
                            // Exact strided gather into the two small FFT workspaces.
                            // cblas_scopy performs no arithmetic or quality reduction.
                            cblas_scopy(Int32(bins), real.baseAddress! + f, Int32(frames), rp.baseAddress!, 1)
                            cblas_scopy(Int32(bins), imaginary.baseAddress! + f, Int32(frames), ip.baseAddress!, 1)
                            ip[0] = 0                             // packed Nyquist = 0
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_fft_zrip(fftSetup, &split, 1, 12, FFTDirection(FFT_INVERSE))
                            frame.withUnsafeMutableBytes { fb in
                                vDSP_ztoc(&split, 1,
                                          fb.baseAddress!.assumingMemoryBound(to: DSPComplex.self),
                                          2, vDSP_Length(nFFT / 2))
                            }
                        }
                    }
                    vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(nFFT))
                    let offset = (f + 2) * hop                    // two empty frames on the left
                    ola.withUnsafeMutableBufferPointer { op in
                        vDSP_vadd(op.baseAddress! + offset, 1, frame, 1,
                                  op.baseAddress! + offset, 1, vDSP_Length(nFFT))
                    }
                }
            }
        }

        // Crop: centre-crop nFFT/2 plus the left pad → offset 2048+1536; scales folded in.
        var out = [Float](repeating: 0, count: segmentSamples)
        var scale = inverseScale / olaEnvelope
        ola.withUnsafeBufferPointer { op in
            vDSP_vsmul(op.baseAddress! + 3584, 1, &scale, &out, 1, vDSP_Length(segmentSamples))
        }
        return out
    }
}
