#!/usr/bin/env python3
"""Prepare Gnarly IPA invitation metadata, validate Ad Hoc profile, and build OTA manifest.

invite_pass.json is metadata, NOT a seven-day runtime enforcement mechanism.
"""
import argparse
import datetime as dt
import json
import os
import plistlib
import subprocess
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

BUNDLE = "com.nightcorelab.app"

def fail(message):
    raise SystemExit("GNARLY INVITE: " + message)

def read_info(ipa):
    with zipfile.ZipFile(ipa) as archive:
        matches = [n for n in archive.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist")]
        if len(matches) != 1: fail("Expected exactly one Payload/*.app/Info.plist")
        data = plistlib.loads(archive.read(matches[0]))
    if data.get("CFBundleIdentifier") != BUNDLE: fail("Unexpected app bundle identifier")
    if not data.get("CFBundleVersion"): fail("Missing app version")
    return data

def prepare(args):
    ipa, dest = Path(args.ipa), Path(args.workdir)
    if dest.exists() and any(dest.iterdir()): fail("Working folder is not empty")
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ipa) as archive:
        for info in archive.infolist():
            target = (dest / info.filename).resolve()
            if not str(target).startswith(str(dest.resolve()) + os.sep): fail("Unsafe IPA path")
            if (info.external_attr >> 16) & 0o170000 == 0o120000: fail("Symlinks not supported in invite IPA")
            if info.file_size > 1_000_000_000: fail("Unexpected large file")
        archive.extractall(dest)
    apps = list((dest / "Payload").glob("*.app"))
    if len(apps) != 1: fail("Expected exactly one app")
    app = apps[0]
    with (app / "Info.plist").open("rb") as f: meta = plistlib.load(f)
    if meta.get("CFBundleIdentifier") != BUNDLE: fail("Bundle identifier differs from Gnarly")
    if not (app / meta.get("CFBundleExecutable", "")).is_file(): fail("Main executable missing")
    if list(app.glob("PlugIns/*.appex")): fail("App extensions require independent provisioning profiles")
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    (app / "invite_pass.json").write_text(json.dumps({
        "schema": 1, "issued_at": now, "expires_at": now + 604800,
        "access_days": 7, "enforced_by_client": False
    }, separators=(",", ":")) + "\n", encoding="utf-8")
    print(app)

def verify_profile(args):
    app = Path(args.app)
    with (app / "Info.plist").open("rb") as f: meta = plistlib.load(f)
    if meta.get("CFBundleIdentifier") != BUNDLE: fail("Bundle identifier does not match")
    target = Path(args.workdir) / "decoded.plist"
    proc = subprocess.run(["openssl", "cms", "-verify", "-inform", "DER",
                           "-in", args.profile, "-noverify", "-out", str(target)],
                          capture_output=True)
    if proc.returncode != 0: fail("Mobileprovision CMS signature failed")
    try:
        with target.open("rb") as f: profile = plistlib.load(f)
    finally:
        target.unlink(missing_ok=True)
    entitlement = profile.get("Entitlements", {})
    team = (profile.get("TeamIdentifier") or [None])[0]
    if not team or entitlement.get("application-identifier") != team + "." + BUNDLE:
        fail("Ad Hoc profile does not match Team ID / bundle")
    if entitlement.get("get-task-allow", False): fail("Development profile is not distribution")
    if not profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        fail("Expected an Ad Hoc profile with registered iPhone UDIDs")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime) or expiry.replace(tzinfo=dt.timezone.utc) <= dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=7):
        fail("Provisioning profile expires within seven days")
    cert = subprocess.run(["openssl", "pkcs12", "-in", args.p12, "-clcerts", "-nokeys",
                           "-passin", "env:GNARLY_P12_PASSWORD"], capture_output=True)
    if cert.returncode != 0: fail("Invalid P12 or password")
    der = subprocess.run(["openssl", "x509", "-outform", "DER"],
                         input=cert.stdout, capture_output=True)
    if der.returncode != 0 or der.stdout not in profile.get("DeveloperCertificates", []):
        fail("P12 certificate is not contained in the provisioning profile")
    valid = subprocess.run(["openssl", "x509", "-inform", "DER", "-checkend", "604800", "-noout"],
                           input=der.stdout, capture_output=True)
    if valid.returncode != 0: fail("P12 signing certificate expires within seven days")
    print("Validated registered-device Ad Hoc profile and distribution certificate")

def check_url(value):
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.fragment:
        fail("Install URLs must be public HTTPS without credentials/fragments")
    if parsed.hostname in ("localhost", "127.0.0.1", "::1"): fail("Local URLs cannot be used for OTA")
    return value

def manifest(args):
    info = read_info(args.ipa)
    assets = [{"kind": "software-package", "url": check_url(args.ipa_url)}]
    if args.display_image_url: assets.append({"kind": "display-image", "url": check_url(args.display_image_url)})
    if args.full_size_image_url: assets.append({"kind": "full-size-image", "url": check_url(args.full_size_image_url)})
    data = {"items": [{"assets": assets, "metadata": {
        "bundle-identifier": info["CFBundleIdentifier"],
        "bundle-version": info["CFBundleVersion"],
        "kind": "software", "title": args.title
    }}]}
    Path(args.output).write_bytes(plistlib.dumps(data, sort_keys=False))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("prepare")
    p.add_argument("--ipa", required=True); p.add_argument("--workdir", required=True)
    p.set_defaults(func=prepare)
    v = commands.add_parser("verify-profile")
    for a in ("profile", "p12", "app", "workdir"): v.add_argument("--" + a, required=True)
    v.set_defaults(func=verify_profile)
    m = commands.add_parser("manifest")
    for a in ("ipa", "ipa-url", "output"): m.add_argument("--" + a, required=True)
    m.add_argument("--title", default="Gnarly")
    m.add_argument("--display-image-url", default="")
    m.add_argument("--full-size-image-url", default="")
    m.set_defaults(func=manifest)
    args = parser.parse_args(); args.func(args)

if __name__ == "__main__":
    main()
