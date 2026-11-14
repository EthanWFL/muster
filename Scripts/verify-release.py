#!/usr/bin/env python3
"""Fail closed unless the app, signed DMG and checksum form one trusted release."""
import argparse
import base64
import hashlib
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(arguments):
    subprocess.run(arguments, check=True, stdout=subprocess.DEVNULL)


def verify(version, artifacts, key_file):
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Version must be X.Y.Z")
    app = artifacts / "Muster.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    embedded_key = info.get("MusterUpdatePublicKey", "")
    require(embedded_key, "App has no trusted update public key; in-app installation cannot work")
    public_key = key_file.read_text().strip()
    require(len(base64.b64decode(public_key, validate=True)) == 32, "Invalid release public key")
    require(embedded_key == public_key, "App does not embed the pinned release public key")
    require(info.get("CFBundleShortVersionString") == version, "App version does not match release")
    require(info.get("CFBundleIdentifier") == "com.muster.app", "Unexpected application identity")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    name = "Muster-" + version + ".dmg"
    dmg, signature = artifacts / name, artifacts / (name + ".sig")
    require(dmg.is_file() and signature.is_file(), "Release requires both DMG and .dmg.sig")
    run(["swift", str(ROOT / "Scripts/sign-update.swift"), "verify", str(dmg), str(signature), public_key])
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    require((artifacts / ("Muster-" + version + ".sha256")).read_text() == digest + "  " + name + "\n",
            "Checksum file does not match this DMG")
    run(["hdiutil", "verify", str(dmg)])
    with tempfile.TemporaryDirectory(prefix="muster-release-check-") as mount:
        run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, str(dmg)])
        try:
            packaged = Path(mount) / "Muster.app"
            require(packaged.is_dir() and not packaged.is_symlink(), "DMG contains no regular Muster.app")
            packaged_info = plistlib.loads((packaged / "Contents/Info.plist").read_bytes())
            require(packaged_info == info, "DMG app metadata differs from the verified app")
            run(["codesign", "--verify", "--deep", "--strict", str(packaged)])
            executable = Path("Contents/MacOS/Muster")
            require(hashlib.sha256((app / executable).read_bytes()).digest() == hashlib.sha256((packaged / executable).read_bytes()).digest(),
                    "DMG executable differs from the verified app")
        finally:
            run(["hdiutil", "detach", mount])
    print("Verified signed release " + version + ": app key, DMG signature, version, code signature and SHA-256 agree.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "dist")
    parser.add_argument("--public-key-file", type=Path, default=ROOT / "Resources/UpdatePublicKey.txt")
    args = parser.parse_args()
    try:
        verify(args.version, args.artifacts.resolve(), args.public_key_file.resolve())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("Release verification failed: " + str(error), file=sys.stderr)
        sys.exit(1)
