# Adapted from demucs-coreml-ios, MIT, Copyright (c) 2026 Nikolai Tsyrenov.
"""The STFT wrapper of htdemucs, reproduced outside the model.

Exact copies of `_spec` / `_ispec` / `_magnitude` / `_mask` (cac=True) from
`demucs.htdemucs` (MIT, Meta). Core ML cannot run these — it has no FFT and no
complex tensors — so they are lifted out of the graph before conversion and
re-implemented on the device with Accelerate/vDSP (`Sources/StemDSP/StemDSP.swift`).
This module is the Python reference the Swift port is checked against.
"""
import math

import torch
import torch.nn.functional as F
from demucs.spec import spectro, ispectro

NFFT = 4096
HOP = 1024
SR = 44100
SEGMENT = 7.8  # = Fraction(39, 5), the htdemucs training segment
SEG_SAMPLES = int(SEGMENT * SR)  # 343980


def pad1d_safe(x, paddings, mode="constant", value=0.0):
    """`demucs.pad1d` without the data-dependent assert (which blocks torch.export)."""
    length = x.shape[-1]
    padding_left, padding_right = paddings
    if mode == "reflect":
        max_pad = max(padding_left, padding_right)
        if length <= max_pad:
            extra_pad = max_pad - length + 1
            extra_pad_right = min(padding_right, extra_pad)
            extra_pad_left = extra_pad - extra_pad_right
            paddings = (padding_left - extra_pad_left, padding_right - extra_pad_right)
            x = F.pad(x, (extra_pad_left, extra_pad_right))
    return F.pad(x, paddings, mode, value)


def spec(x):
    """htdemucs._spec: pad + STFT + slices. x (B,C,N) -> complex (B,C,2048,le)."""
    hl = HOP
    le = int(math.ceil(x.shape[-1] / hl))
    pad = hl // 2 * 3
    x = pad1d_safe(x, (pad, pad + le * hl - x.shape[-1]), mode="reflect")
    z = spectro(x, NFFT, hl)[..., :-1, :]
    return z[..., 2: 2 + le]


def ispec(z, length):
    """htdemucs._ispec: complex (...,2048,T) -> waveform (...,length)."""
    hl = HOP
    z = F.pad(z, (0, 0, 0, 1))
    z = F.pad(z, (2, 2))
    pad = hl // 2 * 3
    le = hl * int(math.ceil(length / hl)) + 2 * pad
    x = ispectro(z, hl, length=le)
    return x[..., pad: pad + length]


def magnitude_cac(z):
    """_magnitude with cac=True: complex (B,C,Fq,T) -> real (B,C*2,Fq,T)."""
    B, C, Fr, T = z.shape
    m = torch.view_as_real(z).permute(0, 1, 4, 2, 3)
    return m.reshape(B, C * 2, Fr, T)


def mask_cac(m):
    """_mask with cac=True: real (B,S,C*2,Fq,T) -> complex (B,S,C,Fq,T)."""
    B, S, C2, Fr, T = m.shape
    out = m.view(B, S, -1, 2, Fr, T).permute(0, 1, 2, 4, 5, 3)
    return torch.view_as_complex(out.contiguous())
