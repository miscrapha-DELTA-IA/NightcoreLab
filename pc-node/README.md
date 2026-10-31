# GNARLY PC Audio Node (Windows)

This worker uses the Windows PC's **own outbound internet connection**. It
needs no Cloudflare Tunnel, inbound firewall holes, residential proxy,
browser extension, or R2 credentials on the PC. The worker authenticates
to the existing Render service over HTTPS, polls at 3-second intervals,
receives an exact 11-character video ID, and attempts an audio-only M4A
fetch with the same bounded yt-dlp version used by the backend.

## Repair a connection error without reinstalling

If the installer prints "Conexao nao aprovada pelo Render", first run
`DIAGNOSTICAR_E_INICIAR.cmd` from the same installed folder. It reuses the
existing Python virtual environment and reports a specific `[DIAGNOSTICO]`
code rather than hiding the original failure. A sleeping Render free service
may take longer than a single 20-second HTTP request to start.

- HTTP 401: token does not match the current backend configuration; never
  paste `node.env` into a public issue or chat.
- HTTP 403: server/edge access denied; inspect access control.
- HTTP 404: deployment does not expose `/pc-node/next`.
- HTTP 503/timeout: backend may be waking up; bounded retries are automatic.
- DNS: verify internet, DNS, VPN, proxy and Windows network access.

During repair, extract the full ZIP into the **parent** directory of the
existing `GNARLY_PC_Node` folder to merge files, not into the folder itself
(which would create a duplicate nested directory).

## First run

1. Install Python 3.11+ from https://python.org/downloads/windows/.
2. Obtain the private **node.env** file from the activation package;
   never commit it or post it publicly.
3. Open PowerShell in this folder and run:
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1`
4. When connectivity checks pass, run:
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1`
5. Optionally run `install-startup.ps1` to launch on Windows login.

Install Deno separately with `winget install DenoLand.Deno` if yt-dlp warns
that a supported JavaScript runtime is unavailable. Run `deno --version`
after restarting PowerShell to verify it is on PATH.

Backend URL is strictly pinned to https://nightcorelab.onrender.com.
Only audio already available to the chosen source can be obtained.
The system does not bypass restrictions or guarantee any YouTube recording.
A download failure is reported to Render without retries on every client.

### Security

- Keep `node.env` private. It contains a worker credential (not R2 keys).
- Server applies lease tokens, bounded job queue and 25MB upload limit.
- No inbound ports or proxy endpoint exposed on the Windows PC.
- Backend receives and validates the audio, then promotes it to its R2 cache.
- Do not share the private activation ZIP or commit it to GitHub.
- For revocation, rotate or remove `GNARLY_PC_NODE_TOKEN` in Render.

### Performance

First play incurs extraction+upload latency, so it's not guaranteed instant.
Once cached in R2, future plays use Cloudflare's edge audio route and do not
require the PC. If the PC is off, the backend reverts to its existing engine.
