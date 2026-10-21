"""Deterministic vocal-like harmonics, bass, chord and percussion; no recordings."""
import torch


def musical_mix(samples=343980, rate=44100):
    generator = torch.Generator().manual_seed(53)
    t = torch.arange(samples, dtype=torch.float32) / rate
    phase = torch.cumsum((180 + 25 * torch.sin(2 * torch.pi * .7 * t)) / rate, 0) * (2 * torch.pi)
    voice = sum(torch.sin(harmonic * phase) / harmonic for harmonic in range(1, 18))
    voice = .10 * voice * torch.clamp(torch.sin(2 * torch.pi * 1.1 * t), min=0)
    beat = torch.remainder(t, .5)
    kick = .18 * torch.sin(2 * torch.pi * (55 * beat - 3 * torch.exp(-beat * 30))) * torch.exp(-beat * 20)
    snare_time = torch.remainder(t + .25, .5)
    snare = .025 * torch.randn(samples, generator=generator) * torch.exp(-snare_time * 35)
    bass = .07 * torch.sin(2 * torch.pi * 55 * t) * (.7 + .3 * torch.cos(2 * torch.pi * 2 * t))
    chord = .025 * sum(torch.sin(2 * torch.pi * note * t) for note in (261.6256, 329.6276, 391.9954))
    left = voice + kick + snare + bass + chord
    right = voice + kick + .8 * snare + bass + torch.roll(chord, 397)
    return torch.stack((left, right))[None]
