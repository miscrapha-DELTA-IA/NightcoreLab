import Accelerate
import Foundation

/// A reusable, single-channel real FFT for OFFLINE visual analysis only.
/// Owns scratch storage and the vDSP setup for the whole source file; nothing
/// is allocated or published from an AVAudioEngine render callback.
///
/// Inspired by AudioVisualizerKit's Hann-windowed FFT and vDSP use, but
/// implemented independently with Apple's documented real-FFT packing.
final class AudioFFTSpectrum {
    typealias Bands = (bass: Double, mid: Double, treble: Double)

    let fftSize: Int
    private let sampleRate: Double
    private let setup: FFTSetup
    private let log2Size: vDSP_Length
    private var ring: [Float]
    private var writeIndex = 0
    private let hann: [Float]
    private var interleaved: [Float]
    private var real: [Float]
    private var imag: [Float]

    /// Power-of-two size is chosen to cover roughly one 12-Hz envelope hop.
    /// A minimum of 2048 samples resolves bass frequencies on 16-kHz fixtures.
    /// Reusable memory is capped at 8192 samples for 96-kHz+ media.
    static func windowSize(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 2048 }
        let target = min(8192, max(2048, Int(sampleRate / 12)))
        var size = 2048
        while size < target { size *= 2 }
        return size
    }

    init?(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        self.sampleRate = sampleRate
        let size = Self.windowSize(sampleRate: sampleRate)
        fftSize = size
        log2Size = vDSP_Length(Int(log2(Double(size))))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))
        else { return nil }
        self.setup = setup

        ring = [Float](repeating: 0, count: size)
        interleaved = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        var coefficients = [Float](repeating: 0, count: size)
        vDSP_hann_window(&coefficients, vDSP_Length(size), 0)
        hann = coefficients
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func consume(_ sample: Float) {
        ring[writeIndex] = sample.isFinite ? min(1, max(-1, sample)) : 0
        writeIndex += 1
        if writeIndex == fftSize { writeIndex = 0 }
    }

    /// Window once per ~83 ms envelope frame. Uses vDSP's real-input FFT:
    /// packed bin zero holds DC/Nyquist; ignore it for the visual 3-band RMS.
    /// The vDSP forward real transform has 2x DFT scaling; the Hann coherent
    /// gain is approximately 1/2, so 2/N restores approximate tone amplitude.
    func bands() -> Bands {
        for i in 0..<fftSize {
            let index = writeIndex + i
            let sample = ring[index < fftSize ? index : index - fftSize]
            interleaved[i] = sample * hann[i]
        }
        let half = fftSize / 2
        interleaved.withUnsafeBytes { bytes in
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    guard let input = bytes.bindMemory(to: DSPComplex.self).baseAddress,
                          let realAddress = re.baseAddress,
                          let imaginaryAddress = im.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realAddress, imagp: imaginaryAddress)
                    vDSP_ctoz(input, 2, &split, 1, vDSP_Length(half))
                    vDSP_fft_zrip(setup, &split, 1, log2Size,
                                  FFTDirection(FFT_FORWARD))
                }
            }
        }

        var lowPower = 0.0
        var midPower = 0.0
        var highPower = 0.0
        let step = sampleRate / Double(fftSize)
        for bin in 1..<half {
            let hz = Double(bin) * step
            let re = Double(real[bin])
            let im = Double(imag[bin])
            let magnitudeSquared = re * re + im * im
            if hz < 180 { lowPower += magnitudeSquared }
            else if hz < 2_200 { midPower += magnitudeSquared }
            else { highPower += magnitudeSquared }
        }
        // Approximately normalized spectral amplitude. All public outputs
        // are explicitly clamped by AudioFeatures to 0...1.
        let amplitudeScale = 2.0 / Double(fftSize)
        func level(_ power: Double) -> Double {
            min(1, sqrt(max(0, power)) * amplitudeScale * 1.5)
        }
        return (level(lowPower), level(midPower), level(highPower))
    }
}
