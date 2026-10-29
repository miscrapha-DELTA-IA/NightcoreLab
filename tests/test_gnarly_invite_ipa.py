import json
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import gnarly_invite_ipa as invite

class Options:
    pass

class InviteSigningSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.ipa = self.root / "unsigned.ipa"
        self.bundle = {
            "CFBundleIdentifier": "com.nightcorelab.app",
            "CFBundleVersion": "59",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleExecutable": "NightcoreLab"
        }
        self._write_ipa()

    def tearDown(self):
        self.temp.cleanup()

    def _write_ipa(self):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/NightcoreLab.app/Info.plist", plistlib.dumps(self.bundle))
            archive.writestr("Payload/NightcoreLab.app/NightcoreLab", b"dummy-binary")

    def test_prepare_has_expiry_metadata_without_falsely_claiming_enforcement(self):
        options = Options()
        options.ipa = str(self.ipa)
        options.workdir = str(self.root / "unpacked")
        invite.prepare(options)
        config = json.loads((Path(options.workdir) / "Payload/NightcoreLab.app/invite_pass.json").read_text())
        self.assertEqual(config["access_days"], 7)
        self.assertEqual(config["expires_at"] - config["issued_at"], 604800)
        self.assertIs(config["enforced_by_client"], False)

    def test_manifest_uses_signed_app_bundle_and_version(self):
        options = Options()
        options.ipa = str(self.ipa)
        options.ipa_url = "https://cdn.example.com/invites/gnarly.ipa"
        options.output = str(self.root / "manifest.plist")
        options.title = "Gnarly"
        options.display_image_url = ""
        options.full_size_image_url = ""
        invite.manifest(options)
        document = plistlib.loads(Path(options.output).read_bytes())
        data = document["items"][0]
        self.assertEqual(data["metadata"]["bundle-identifier"], "com.nightcorelab.app")
        self.assertEqual(data["metadata"]["bundle-version"], "59")
        self.assertEqual(data["assets"][0]["url"], options.ipa_url)

    def test_rejects_http_and_local_urls(self):
        for url in ("http://localhost/a.ipa", "https://127.0.0.1/a.ipa", "http://bad.test/a.ipa"):
            with self.assertRaises(SystemExit):
                invite.check_url(url)

    def test_rejects_wrong_bundle_id(self):
        self.bundle["CFBundleIdentifier"] = "com.nightcorelab.gnarly"
        self._write_ipa()
        with self.assertRaises(SystemExit):
            invite.read_info(self.ipa)

    def test_rejects_path_traversal_in_source_ipa(self):
        with zipfile.ZipFile(self.ipa, "a") as archive:
            archive.writestr("../../outside.txt", b"malicious")
        options = Options()
        options.ipa = str(self.ipa)
        options.workdir = str(self.root / "unpacked")
        with self.assertRaises(SystemExit):
            invite.prepare(options)

if __name__ == "__main__":
    unittest.main()
