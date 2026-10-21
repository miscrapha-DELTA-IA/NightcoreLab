---
title: Gnarly Free Stems
emoji: 🎛️
colorFrom: blue
colorTo: purple
sdk: gradio
sdk_version: 6.30.0
python_version: 3.12.12
app_file: app.py
pinned: false
license: mit
---

HTDemucs four-source separation for the Gnarly beta. Select **ZeroGPU** hardware.
Requires a `STEMS_CLOUD_SIGNING_KEY` secret shared with Render and a
`STEMS_CLOUD_SPACE_URL` variable equal to this Space's public HTTPS origin.

Audio is uploaded directly by the iPhone after an explicit cloud action. Requests
are anonymous to Hugging Face: no HF access token or prepaid credits are used.
The API requires a short-lived, single-use authorization signed by Render and
bound to the SHA-256 and size of the source audio. No alternate provider exists.
Free hosting eligibility and provider quotas still apply. No uptime/speed promise.

Audio and results are temporary. This is a public Gradio Space: someone with a
result URL may access it until cleanup (at most approximately one hour). Do not
send confidential recordings. Gradio cache cleanup runs every ten minutes.
