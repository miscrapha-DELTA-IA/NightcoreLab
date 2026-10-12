# Creative Engine — AudioVisualizerKit FFT adaptation

Reference reviewed: https://github.com/Kyome22/AudioVisualizerKit
Upstream license: MIT; last pushed August 2024.

## Decision

**Adapt FFT techniques**, do not install AudioVisualizerKit as an SPM
dependency. Its AudioAnalyzer owns an AVAudioEngine and AVAudioPlayerNode;
NightcoreLab already has one playback graph and must not duplicate it.

## Implemented

- Original Swift `AudioFFTSpectrum.swift` backed by Apple's Accelerate/vDSP:
  reusable FFT setup, Hann window, stable 2048/4096/8192 power-of-two
  transforms, scratch arrays reused for each window, and three frequency
  bands (<180 Hz, 180–2200 Hz, >2200 Hz).
- Existing `AudioFeatureAnalyzer` retains read-only AVAudioFile decoding,
  RMS, beat-onset heuristic, max 20-minute limit and ~12-Hz timeline.
- Each stereo channel is analyzed separately. Per-channel spectral levels
  and RMS energy are combined using root-mean-square, rather than an
  anti-phase-cancelling mono downmix.
- `AudioFeatureEngine`, `AudioVisualMapper`, player and karaoke
  retain their existing interfaces, timestamps and power/cancellation
  behavior. Visual analysis is still off unless explicitly enabled.
- Apple Accelerate is a native iOS 17 framework; no new package or
  AVAudioEngine tap was introduced.

## Frequency conventions

The real FFT returns packed complex bins with special DC/Nyquist in slot 0;
that bin is excluded from the normalized visual bands. vDSP forward FFT
scales the DFT by 2 and the Hann window reduces coherent gain by 1/2,
so the 2/N transform scale gives approximate visual amplitude before
a bounded visualization gain. This is not a clinical/acoustic dB meter,
and `beatDetected` is still an onset heuristic rather than BPM detection.

A 48-kHz file uses 4096 FFT samples per window, at roughly 12 feature
frames/second. FFT setup and working buffers are reused for the lifetime of
each channel analyzer. CPU decoding runs only from the detached utility
task when a visual effect is requested, not from the render callback.

## Validation

`AudioFFTAnalyzerTests`: tone separation at 16k, 44.1k and 48k;
zero-signal safety; final partial window; anti-phase stereo CAF;
power-of-two limits; default `AudioFeatureEngine` behavior.

Existing `AudioVisualMapperTests`, `AudioFeaturesTests` and
`FosforaAudioVisualBridgeTests` remain regression tests.

Future work: benchmarks on a physical iPhone with Time Profiler and Energy
Log before enabling analysis by default. It remains opt-in.
