# Stage 41 — Dev stem isolation and compact offline audio

- The baseline remains **Stage 40** (three non-stitchable Metal compute kernels).
- The **score HUD** is opt-out with `karaoke.showScoreHUD`; the Story preview already has a separate `showsScoreStamp` toggle.
- Estimated, not verified, lyric timings now use phonetic vowel weighting and 20 ms center-band energy; genuine enhanced-LRC and ASS timestamps are left untouched.
- Offline originals are transcoded off the UI thread into actual AAC M4A at 144 kbps. The disposable LRU cache targets 20 tracks / 100 MiB. Pinned offline tracks and currently playing/queued files are protected; therefore the cap is *best effort* if protected files alone exceed the budget. Duration determines file size: 20 long tracks may exceed 85 MB.
- All four prepared stem streams use the existing `AVAudioEngine` and a shared source timeline. For 0% stem volume, only the corresponding prepared node is muted. Live EQ is neutral while processing, rather than pretending to isolate a source.
- **On device:** 2048-pt Hann STFT, 75% overlap, complementary spectral masks and overlap-add produce four *approximate* separated streams cached as AAC. They can exhibit audible source leakage. They are not a neural Demucs model.
- **Actual model isolation, dev-only:** Enable the experimental Demucs switch in Música, enter a developer HTTPS endpoint and bearer token. The token is saved to iOS Keychain. Explicit enabling authorizes sending this local track to the configured host. The server requires `STEMS_DEV_ENABLED=1`, `STEMS_DEV_TOKEN` of at least 16 characters, Python package `demucs` installed alongside FFmpeg, sufficient disk/memory and `htdemucs` weights. Default is **disabled**. The server runs `python -m demucs -n htdemucs` and exposes four independently rendered WAV tracks, then the app checks all four have matching durations.
- Suggested local setup: `pip install demucs`; `export STEMS_DEV_ENABLED=1`; `export STEMS_DEV_TOKEN=<strong-random-token>`; `uvicorn main:app --host 127.0.0.1 --port 8000` from `backend/`. To connect from a physical iPhone, use an authenticated HTTPS tunnel or trusted dev host; the iPhone cannot reach a laptop's `localhost` directly. Review the Demucs code/model license before redistribution or deployment.
- This optional backend is **not** deployed to a hosted production environment and is intentionally excluded from the ordinary app download flow.
- Re-run the 14 Stage 40 Metal tests plus all tests before publishing the v41 IPA; inspect device mic route and real-source stem quality separately on an iPhone.

## Connect a physical iPhone to a local Windows HTDemucs worker

The production `https://nightcorelab.onrender.com` service is on a small free
plan for music search/download; **do not install CPU-intensive Demucs there**.
Instead, the Stage 41 branch has a standalone `backend/demucs_app.py` that
imports only FastAPI and the opt-in secured `/api/stems` router.

From Windows PowerShell (Python 3.11 and winget required):

```powershell
git clone https://github.com/miscrapha-DELTA-IA/NightcoreLab.git
cd NightcoreLab
git switch stage-41-dev-stems-mic-and-karaoke-share-final
powershell -ExecutionPolicy Bypass -File .\scripts\dev-stems\start-demucs-windows.ps1
```

If this repository is already cloned, use `git pull` on the same branch
instead of cloning again. The launcher checks/installs FFmpeg and cloudflared,
creates `backend/.venv-demucs`, installs `requirements-demucs-dev.txt`
(Demucs/PyTorch may be a large first download), creates a cryptographically
random 64-hex-character bearer token under `%LOCALAPPDATA%\NightcoreLab\DevStems`
OUTSIDE of Git, starts only `uvicorn demucs_app:app` on localhost:8765,
checks `/health`, and opens a Cloudflare Quick Tunnel. Keep the PowerShell
window open while using the app. The quick HTTPS hostname may change after
each restart.

On iPhone: **Música → STEMS → Separação real · Modo DEV**. Enable
**Usar servidor Demucs (envia áudio)**; paste the displayed
`https://....trycloudflare.com` BASE URL (no `/api/stems`) and the generated
token into the two fields. Then tap **Preparar com Demucs**. This explicit
action reloads the currently selected source even when approximate local stems
already exist, without changing the single AVAudioEngine. The original audio
continues playing while the job is processed; status shows **Demucs** only
after all four independent streams are validated. Error details and retry are
available in the STEMS panel.

### Security and operational notes

- The token is not included in GitHub commits, IPA files or `UserDefaults`;
  iPhone storage is Keychain. Do not share the tunnel URL together with its token.
- Cloudflare Quick Tunnel supplies TLS and a temporary public address, NOT
  access control by itself. Authorization is enforced by the bearer token on
  every `/api/stems` call. Only use files you are authorized to process.
- CPU separation can take minutes. The app polls for up to 15 minutes, while
  the dev worker has a 12-minute subprocess timeout. It is not live separation.
- WAV stem outputs consume significantly more storage than the 20-track
  compressed AAC music cache. They are dev artifacts, not part of that quota.
- For production/always-on use, obtain a GPU-capable dedicated host and
  review the package/model licenses. Do not deploy the unbounded CPU workload
  into the already running free Render service.
- The GitHub/Render connector cannot install a local PowerShell/Python process,
  so one Windows execution of the launcher is required.
