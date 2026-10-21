"""Exercise the exact anonymous Gradio HTTP protocol used by the iPhone.

Only a tiny synthetic WAV is echoed. No model, audio upload to a provider,
GPU, HF account or third-party service is involved.
"""
import json
from pathlib import Path
import socket
import tempfile
import unittest
import wave

import httpx
try:
    import gradio as gr
except ImportError:
    gr = None


@unittest.skipIf(gr is None, "Install Gradio 6.30.0 for the Space HTTP contract test")
class GradioWireContractTests(unittest.TestCase):
    def test_direct_upload_call_sse_and_four_file_downloads(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.wav"
            with wave.open(str(source), "wb") as wav:
                wav.setparams((2, 2, 44100, 441, "NONE", "not compressed"))
                wav.writeframes(b"\x00" * 441 * 4)
            def separate(path, ticket):
                if ticket != "signed-test-ticket":
                    raise gr.Error("Invalid authorization")
                return (path, path, path, path, {"model": "htdemucs"})
            def community(path, mode, force):
                assert mode == "Core instruments — 4 tracks"
                assert force is False
                return ("Ready", [path] * 4, None, "force=false")
            with gr.Blocks(analytics_enabled=False) as demo:
                audio, ticket = gr.File(type="filepath"), gr.Textbox()
                files = [gr.File() for _ in range(4)]
                metadata = gr.JSON()
                gr.Button().click(separate, [audio, ticket], files + [metadata], api_name="separate")
                community_audio = gr.Audio(type="filepath")
                mode = gr.Radio(["Core instruments — 4 tracks"])
                state = gr.State(False)
                community_outputs = [gr.Markdown(), gr.File(file_count="multiple"), gr.File(), gr.HTML()]
                gr.Button().click(community, [community_audio, mode, state], community_outputs,
                                  api_name="community")
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            demo.queue(max_size=2).launch(server_name="127.0.0.1", server_port=port,
                prevent_thread_lock=True, quiet=True, max_file_size=35 * 1024 * 1024)
            try:
                with httpx.Client(base_url=f"http://127.0.0.1:{port}", trust_env=False, timeout=15) as client:
                    with source.open("rb") as handle:
                        response = client.post("/gradio_api/upload", files={"files": ("source.wav", handle, "audio/wav")})
                    self.assertEqual(response.status_code, 200, response.text)
                    path = response.json()[0]
                    response = client.post("/gradio_api/call/separate", json={"data": [
                        {"path": path, "meta": {"_type": "gradio.FileData"}}, "signed-test-ticket"]})
                    self.assertEqual(response.status_code, 200, response.text)
                    event = response.json()["event_id"]
                    self.assertRegex(event, "^[a-f0-9]{32}$")
                    response = client.get("/gradio_api/call/separate/" + event)
                    self.assertEqual(response.status_code, 200)
                    chunks = response.text.split("\n\n")
                    complete = next(c for c in chunks if "event: complete" in c)
                    values = json.loads(next(line[6:] for line in complete.splitlines() if line.startswith("data: ")))
                    self.assertEqual(len(values), 5)
                    self.assertEqual(values[4]["model"], "htdemucs")
                    for file in values[:4]:
                        url = httpx.URL(file["url"])
                        self.assertTrue(url.path.startswith("/gradio_api/file="))
                        result = client.get(file["url"])
                        self.assertEqual(result.status_code, 200)
                        self.assertEqual(result.content, source.read_bytes())
                    # The simple HTTP API omits the third State argument, exactly
                    # like the public four-stem BS-Roformer endpoint.
                    response = client.post("/gradio_api/call/community", json={"data": [
                        {"path": path, "meta": {"_type": "gradio.FileData"}}, "Core instruments — 4 tracks"]})
                    self.assertEqual(response.status_code, 200)
                    response = client.get("/gradio_api/call/community/" + response.json()["event_id"])
                    complete = next(c for c in response.text.split("\n\n") if "event: complete" in c)
                    values = json.loads(next(line[6:] for line in complete.splitlines() if line.startswith("data: ")))
                    self.assertEqual(len(values[1]), 4)
                    self.assertEqual(values[3], "force=false")
            finally:
                demo.close()


if __name__ == "__main__":
    unittest.main()
