#!/usr/bin/env python3
"""Release packaging must embed the pinned key and refuse unsafe or mismatched signing keys."""
import base64
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
public = (ROOT / "Resources/UpdatePublicKey.txt").read_text().strip()
assert len(base64.b64decode(public, validate=True)) == 32
info_file = ROOT / "dist/Muster.app/Contents/Info.plist"
before = info_file.read_bytes()
assert plistlib.loads(before)["MusterUpdatePublicKey"] == public

with tempfile.TemporaryDirectory(prefix="muster-release-config-") as directory:
    root = Path(directory)
    key = root / "test.key"
    subprocess.run(["swift", "Scripts/sign-update.swift", "generate-key", str(key)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    for path in [root / "missing.key", key]:
        env = dict(os.environ, MUSTER_UPDATE_KEY_FILE=str(path))
        result = subprocess.run(["bash", "Scripts/package.sh", "--dmg", "9.9.9"], cwd=ROOT, env=env, capture_output=True)
        assert result.returncode != 0, "Unsigned or mismatched release was accepted"
        if path == key:
            assert b"Signing key does not match Resources/UpdatePublicKey.txt" in result.stderr
        assert info_file.read_bytes() == before, "Rejected packaging changed the existing app"
    key.chmod(0o644)
    result = subprocess.run(["swift", "Scripts/sign-update.swift", "check-private-key", str(key), str(ROOT)], cwd=ROOT, capture_output=True)
    assert result.returncode != 0, "World-readable private key was accepted"
    assert b"unsafeKeyFile" in result.stderr
    key.chmod(0o600)
    result = subprocess.run(["swift", "Scripts/sign-update.swift", "check-private-key", str(key), str(root)], cwd=ROOT, capture_output=True)
    assert result.returncode != 0, "Private key inside a repository was accepted"
    assert b"unsafeKeyFile" in result.stderr
print("PASS: bundled public key and fail-closed release signing configuration.")
