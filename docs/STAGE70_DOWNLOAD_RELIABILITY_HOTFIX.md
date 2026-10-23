# Stage 70 — Playback and Download Reliability Hotfix

## Production evidence, 23 Oct 2026

- Service: `NightcoreLab` on Render, plan **Free**, main branch auto-deployed (last service commit `bedab821`).
- Logs show an instance shutting down after idle and a later startup; UI text "servidor acordando" is consistent with Render cold starts.
- Production logs include bursts of `/v1/search` and `/v1/suggest` for every incremental substring and intermittent 429 responses. The existing Omnibox was sending **two queries per keystroke after 220 ms**.
- A `yt-dlp [related]` **HTTP 429** warning was followed by 429 on `/download`. In backend source, its logger erroneously activated a 300-second global YouTube download cooldown, even if only the optional recommendation Mix was denied.
- Backend sometimes works: observed `yt-dlp [logado/web]` producing actual M4A and `GET /download` 200; the incident is intermittent, not a universal audio decoder failure.

## Hotfix split

### On-device v70 branch
- The Omnibox keeps local history and cache on every edit but sends requests **only when the Search key is pressed or a suggestion chosen**. On submission it still obtains primary `/v1/search` and `/v1/suggest`, and keeps the explicit legacy fallback.
- Canceled/older search generations cannot overwrite new results.
- Network 502/503/504 and transient transport errors receive at most two further attempts with 8s and 18s waits; selection generation cancels obsolete retries.
- A real 429 no longer holds the foreground player spinner for 60–300 seconds. It opens a breaker and shows a specific 429/queue/YouTube cooldown message with Retry-After.
- Saved/offline audio is served immediately without a server request. Prefetch still only targets the immediate successor.
- No changes to UI layout, shaders, Stems, Karaoke, queue architecture, or AVAudioEngine. Visible build badge v70 and CFBundleVersion 70 distinguish it from earlier IPAs.

### Companion backend hotfix
- PR #145 `fix/backend-related-download-cooldown-isolation`, based on `main`, prevents `related` metadata failures from quarrantining explicit audio downloads.
- Real download-side YouTube 429 remains protected with Retry-After; no attempt to bypass rate limits.
- Render Free sleeping is a **hosting limitation**, not fixed by client code. An always-on paid instance is a possible hosting improvement; do not imply a keepalive ping guarantees 24/7 operation.

## Verification gates

- Backend Unit and Playback Backend Regression must pass before production merge/deploy; inspect Render app logs afterwards.
- iOS full `Build Unsigned IPA (Free Route)`, karaoke, share and continuity tests must pass before distributing a v70 IPA.
- Verify on a physical iPhone: a search typed slowly creates **no search HTTP requests until submit**; submissions yield results; playback starts for 3 unrelated tracks in succession; deliberate offline revisit works even when Render is sleeping; HTTP 429 shows YouTube/rate-limit message without claiming the server is asleep; background vs foreground does not lose next-track selection.
- Do not change invitation from Build 66 or merge visual Stage 69 experimental until device QA.
