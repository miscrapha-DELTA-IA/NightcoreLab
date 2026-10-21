"""ZeroGPU-only worker. Never import this heavyweight module on Render."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

# spaces must be imported before torch so ZeroGPU patches CUDA at startup.
import spaces
import torch
import gradio as gr
import soundfile as sf
from demucs.apply import apply_model
from demucs.pretrained import get_model

from tickets import GPU_SECONDS, MAX_BYTES, MAX_SECONDS, MODEL, verify

if os.environ.get("SPACES_ZERO_GPU", "").lower() not in {"true", "1"}:
    raise RuntimeError("Only ZeroGPU is allowed; CPU and paid dedicated GPUs are disabled")
SECRET = os.environ.get("STEMS_CLOUD_SIGNING_KEY", "")
AUDIENCE = os.environ.get("STEMS_CLOUD_SPACE_URL", "").rstrip("/")
if len(SECRET) < 32 or not AUDIENCE.startswith("https://") or not AUDIENCE.endswith(".hf.space"):
    raise RuntimeError("Configure the signing key and exact Space URL before startup")

model = get_model(MODEL).eval().to("cuda")
_lock = threading.Lock()
_used: dict[str, float] = {}
_recent: list[float] = []


@spaces.GPU(duration=GPU_SECONDS)
def inference(audio: torch.Tensor) -> torch.Tensor:
    with torch.inference_mode():
        # Same real four-source model as iPhone. A single deterministic pass;
        # avoid random shift ensembles that multiply runtime and quota usage.
        return apply_model(model, audio[None].to("cuda"), device="cuda",
                           shifts=0, split=True, overlap=0.25, progress=False)[0].cpu()


def separate(source: str, ticket: str):
    folder: Path | None = None
    try:
        claims = verify(SECRET, ticket, AUDIENCE)
        path = Path(source)
        if path.stat().st_size != claims["bytes"] or path.stat().st_size > MAX_BYTES:
            raise ValueError("O áudio excede o limite autorizado")
        with path.open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        if digest != claims["sha256"]:
            raise ValueError("O áudio não corresponde à autorização")
        with _lock:
            now = time.time()
            for key, expiry in tuple(_used.items()):
                if expiry < now:
                    del _used[key]
            _recent[:] = [stamp for stamp in _recent if stamp > now - 86400]
            if claims["id"] in _used or len(_recent) >= 2:
                raise ValueError("Autorização já utilizada ou limite diário atingido")
            _used[claims["id"]] = claims["exp"]
            _recent.append(now)
        folder = Path(tempfile.mkdtemp(prefix="gnarly-stems-"))
        decoded = folder / "decoded.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(path),
                        "-t", str(MAX_SECONDS + 1), "-ar", "44100", "-ac", "2",
                        "-c:a", "pcm_f32le", str(decoded)], check=True, timeout=45,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        samples, rate = sf.read(decoded, dtype="float32", always_2d=True)
        seconds = len(samples) / rate
        if not 0 < seconds < MAX_SECONDS or abs(seconds - claims["seconds"]) > 0.25:
            raise ValueError("Duração do áudio inválida")
        audio = torch.from_numpy(samples.T.copy())
        reference = audio.mean(0)
        mean, std = reference.mean(), reference.std().clamp_min(1e-8)
        output = inference((audio - mean) / std) * std + mean
        files, hashes = [], {}
        for name in ("vocals", "other", "drums", "bass"):
            destination = folder / (name + ".wav")
            # Four stereo WAVs with consistent sample counts, no clipping/rescale
            # per stem. Float preserves the model's shared reconstruction gain.
            sf.write(destination, output[model.sources.index(name)].T.numpy(), rate, subtype="FLOAT")
            files.append(str(destination))
            with destination.open("rb") as handle:
                hashes[name] = hashlib.file_digest(handle, "sha256").hexdigest()
        return (*files, {"model": MODEL, "source_hash": digest, "frames": len(samples),
                         "sample_rate": rate, "sha256": hashes})
    except Exception:
        # Never expose filesystem locations, tickets, URLs or provider internals.
        raise gr.Error("Separação indisponível: cota gratuita, áudio ou autorização inválida. "
                       "Tente mais tarde ou separe no iPhone.") from None
    finally:
        # Gradio copies returned files to its managed cache before cleanup below
        # is possible; leave successful result folders for a bounded janitor.
        if folder is not None:
            (folder / "decoded.wav").unlink(missing_ok=True)


def cleanup():
    while True:
        for path in Path(tempfile.gettempdir()).glob("gnarly-stems-*"):
            try:
                if time.time() - path.stat().st_mtime > 3600:
                    shutil.rmtree(path, ignore_errors=True)
            except OSError:
                pass
        time.sleep(60)


threading.Thread(target=cleanup, daemon=True).start()
with gr.Blocks(delete_cache=(600, 3600), analytics_enabled=False) as demo:
    gr.Markdown("Gnarly · separação real com GPU gratuita, sujeita a cotas e filas.")
    source = gr.File(type="filepath", file_types=["audio"])
    ticket = gr.Textbox(label="Autorização temporária", type="password")
    outputs = [gr.File(label=name) for name in ("Voz", "Outros", "Bateria", "Baixo")]
    manifest = gr.JSON()
    gr.Button("Separar").click(separate, [source, ticket], outputs + [manifest],
                              api_name="separate", concurrency_limit=1)

demo.queue(max_size=2).launch(max_file_size=MAX_BYTES, show_error=False)
