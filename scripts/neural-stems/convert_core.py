# Adapted from demucs-coreml-ios, MIT, Copyright (c) 2026 Nikolai Tsyrenov.
#!/usr/bin/env python3
"""htdemucs (Demucs v4) -> Core ML, with the complex maths lifted out of the graph.

Core ML has no FFT and no complex tensors, and htdemucs keeps all of its complex maths in
`_spec` / `_ispec` / `_mask` (cac=True). So we export only the *core*: it takes the spectrogram
with real/imag as channels plus the raw waveform, and returns the stem spectrograms (before the
mask) plus the time branch. Everything complex happens outside — in Python here, on Accelerate
on the device.

    core inputs  : mix (1,2,343980), spec_ri (1,4,2048,336)
    core outputs : spec_stems (1,4,4,2048,336), time_stems (1,4,2,343980)
    reassembly   : istft(mask_cac(spec_stems)) + time_stems

`forward` below is `demucs.htdemucs.HTDemucs.forward` (MIT, Meta) with the spec calls replaced
by inputs/outputs; cac=True, use_train_segment=True. Stage 2 asserts that this surgery is
numerically identical to the stock model before anything is converted.

Run from a directory where `stemcommon.py` is importable:  python convert_core.py
"""
import sys
import time
import traceback

import numpy as np
import torch
from einops import rearrange

import stemcommon as sc

STAGE = lambda s: print(f"\n=== {s} ===", flush=True)


class HTDemucsCore(torch.nn.Module):
    """The exportable core of htdemucs: (mix, spec_ri) -> (spec_stems_ri, time_stems)."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, mix, spec_ri):
        m = self.m
        x = spec_ri
        B, C, Fq, T = x.shape

        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)

        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)

        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_downsampler_t(xt)

        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]

        xt = xt.view(B, S, -1, mix.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]
        return x, xt


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--convert-only", action="store_true")
    parser.add_argument("--output", default="htdemucs_core.mlpackage")
    args = parser.parse_args()
    torch.set_num_threads(2)
    STAGE("1. Load + surgery")
    import demucs.hdemucs as hd
    import demucs.htdemucs as htd
    # pad1d carries a data-dependent assert that torch.export refuses; the logic is unchanged.
    hd.pad1d = sc.pad1d_safe
    htd.pad1d = sc.pad1d_safe
    import json
    import pathlib
    import yaml
    from huggingface_hub import hf_hub_download
    from demucs.hf import load_safetensors_model
    manifest = json.loads((pathlib.Path(__file__).parent / "model-manifest.json").read_text())
    repo, revision = manifest["huggingface_repo"], manifest["huggingface_revision"]
    with open(hf_hub_download(repo, "htdemucs.yaml", revision=revision)) as source:
        bag = yaml.safe_load(source)
    assert len(bag["models"]) == 1
    checkpoint = hf_hub_download(repo, bag["models"][0] + ".safetensors", revision=revision)
    model = load_safetensors_model(checkpoint).eval()
    assert model.sources == ["drums", "bass", "other", "vocals"]
    core = HTDemucsCore(model).eval()

    n = sc.SEG_SAMPLES
    torch.manual_seed(7)
    mix = torch.randn(1, 2, n) * 0.1

    STAGE("2. Sanity: core + wrapper == stock forward")
    with torch.no_grad():
        z = sc.spec(mix)
        spec_ri = sc.magnitude_cac(z)
        spec_stems, time_stems = core(mix, spec_ri)
        wave_spec = sc.ispec(sc.mask_cac(spec_stems), n)
        assembled = (wave_spec + time_stems).numpy()
        ref = model(mix).numpy()
    err = np.abs(assembled - ref).max()
    print(f"max|assembled - original| = {err:.2e}")
    if err > 1e-3:
        print("SURGERY IS WRONG — stop")
        return 1

    STAGE("3. torch.export + decompositions")
    try:
        with torch.no_grad():
            ep = torch.export.export(core, (mix, spec_ri), strict=False)
            ep = ep.run_decompositions({})
        print("export OK")
    except Exception:
        traceback.print_exc()
        return 2

    STAGE("4. coremltools.convert (fp16)")
    import coremltools as ct
    try:
        mlmodel = ct.convert(
            ep,
            minimum_deployment_target=ct.target.iOS18,
            compute_precision=ct.precision.FLOAT16,
            convert_to="mlprogram",
        )
    except Exception:
        traceback.print_exc()
        return 3
    out = args.output
    mlmodel.author = "Meta Platforms, Inc.; Core ML port by Nikolai Tsyrenov / Gnarly"
    mlmodel.license = "MIT"
    mlmodel.short_description = "HTDemucs v4: four real neural music sources"
    mlmodel.user_defined_metadata["gnarly.model_id"] = "htdemucs-v4-core-fp16-v1"
    mlmodel.user_defined_metadata["sources"] = ",".join(model.sources)
    mlmodel.user_defined_metadata["segment_samples"] = str(n)
    mlmodel.save(out)
    print("saved:", out)

    import pathlib
    fixture = pathlib.Path(out).parent / "golden"
    fixture.mkdir(exist_ok=True)
    mix.numpy().tofile(fixture / "mix.f32")
    ref.tofile(fixture / "reference.f32")
    if args.convert_only:
        print("CONVERTED; runtime gate must run on macOS before delivery")
        return 0
    STAGE("5. Core ML vs PyTorch (fp16 drift)")
    # Reload with explicit compute units: the default (ALL) lets the Neural Engine run this
    # model, and the ANE returns garbage here — NaNs on the first prediction. Same reason the
    # iOS side must use .cpuAndGPU. See docs/GOTCHAS.md.
    mlmodel = ct.models.MLModel(out, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    in_names = [i.name for i in mlmodel.get_spec().description.input]
    feed = {in_names[0]: mix.numpy(), in_names[1]: spec_ri.numpy()}
    t0 = time.time()
    pred = mlmodel.predict(feed)
    t_ml = time.time() - t0
    outs = {o.name: pred[o.name] for o in mlmodel.get_spec().description.output}
    got_spec, got_time = list(outs.values())
    if got_spec.ndim == 4:  # output order is not guaranteed
        got_spec, got_time = got_time, got_spec
    with torch.no_grad():
        wave_ml = sc.ispec(sc.mask_cac(torch.from_numpy(got_spec.copy())), n)
        final_ml = (wave_ml + torch.from_numpy(got_time.copy())).numpy()
    corr = np.corrcoef(ref.ravel(), final_ml.ravel())[0, 1]
    mae = np.abs(ref - final_ml).mean()
    print(f"corr={corr:.5f}  MAE={mae:.6f}  predict {t_ml:.1f}s (segment {sc.SEGMENT}s)")
    print("GATE:", "GREEN" if corr > 0.98 else "YELLOW/RED — listen before trusting")
    return 0 if np.isfinite(corr) and corr > 0.98 and mae < 0.01 else 4


if __name__ == "__main__":
    sys.exit(main())
