#!/usr/bin/env python3
"""Exercise download -> verify -> replace -> relaunch using isolated, signed app fixtures."""
import json
import argparse
import os
import plistlib
import platform
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--release-artifacts", type=Path)
parser.add_argument("--published", action="store_true")
args = parser.parse_args()
if args.published and not args.release_artifacts:
    parser.error("--published requires --release-artifacts for an isolated installed-app copy")


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="muster-update-install-test-") as temporary:
    root = Path(temporary)
    key = root / "test-private.key"
    public = subprocess.check_output(["swift", "Scripts/sign-update.swift", "generate-key", str(key)], cwd=ROOT, text=True).strip()
    (root / "public.key").write_text(public)
    marker = root / "restarted-version.txt"
    stub = root / "stub.swift"
    stub.write_text('''import Foundation
let app = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
try (info["CFBundleShortVersionString"] as! String).write(toFile: info["MusterFixtureMarker"] as! String, atomically: true, encoding: .utf8)
''')
    binary = root / "Muster"
    swift_target = platform.machine() + "-apple-macos14.0"
    run(["swiftc", "-target", swift_target, str(stub), "-o", str(binary)])

    def app_at(path, version, trusted_key):
        (path / "Contents/MacOS").mkdir(parents=True)
        shutil.copy2(binary, path / "Contents/MacOS/Muster")
        info = {"CFBundleIdentifier": "com.muster.app", "CFBundleExecutable": "Muster", "CFBundleName": "Muster",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1", "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
            "MusterUpdatePublicKey": trusted_key, "MusterFixtureMarker": str(marker)}
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run(["codesign", "--force", "--sign", "-", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    app_at(root / "installed/Muster.app", "1.1.0", public)
    app_at(root / "payload/Muster.app", "1.1.1", public)
    app_at(root / "changed/Muster.app", "1.1.1", "invalid-key")
    for source, name in [("payload", "update"), ("changed", "changed-key")]:
        image = root / (name + ".dmg")
        run(["hdiutil", "create", "-quiet", "-volname", "Muster Test", "-srcfolder", str(root / source), "-format", "UDZO", str(image)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(["swift", "Scripts/sign-update.swift", "sign", str(image), str(key), public, str(root / (name + ".sig"))])
    objects = []
    for target in ["MusterCore", "Muster", "Yams"]:
        file_map = json.loads((ROOT / f".build/debug/{target}.build/output-file-map.json").read_text())
        objects += [entry["object"] for source, entry in file_map.items() if source and not source.endswith("/MusterApp.swift")]
    objects += [str(path) for path in (ROOT / ".build/debug/CYaml.build").rglob("*.o")]
    harness = root / "update-test"
    run(["swiftc", "-target", swift_target, "-parse-as-library", "-I", str(ROOT / ".build/debug/Modules"), "-Xcc", "-fmodule-map-file=" + str(ROOT / "Vendor/Yams/Sources/CYaml/include/module.modulemap"),
        "-Xcc", "-I" + str(ROOT / "Vendor/Yams/Sources/CYaml/include"), "Scripts/test-update-installation.swift", *objects, "-o", str(harness)])
    env = dict(os.environ, MUSTER_UPDATE_FIXTURE=str(root))
    run([str(harness), str(root)], env=env, timeout=90)
    deadline = time.monotonic() + 20
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    assert marker.exists() and marker.read_text() == "1.1.1", "Replacement app was not relaunched"
    assert not list((root / "installed").glob(".Muster-*")), "Replacement left temporary app entries"
    print("PASS: replacement app launched at the same isolated path and reported 1.1.1; no Agent configuration was accessed.")
    if args.release_artifacts:
        actual = root / "actual-release"
        installed = actual / "installed/Muster.app"
        shutil.copytree(args.release_artifacts / "Muster.app", installed, symlinks=True)
        info_file = installed / "Contents/Info.plist"
        info = plistlib.loads(info_file.read_bytes())
        assert info["CFBundleShortVersionString"] == "1.1.1"
        actual_key = info["MusterUpdatePublicKey"]
        assert actual_key == (ROOT / "Resources/UpdatePublicKey.txt").read_text().strip()
        # Simulate an older *key-bearing* installed version, never the published keyless 1.1.0.
        info["CFBundleShortVersionString"] = "1.1.0"
        info_file.write_bytes(plistlib.dumps(info))
        run(["codesign", "--force", "--sign", "-", str(installed)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (actual / "public.key").write_text(actual_key)
        if not args.published:
            shutil.copy2(args.release_artifacts / "Muster-1.1.1.dmg", actual / "update.dmg")
            shutil.copy2(args.release_artifacts / "Muster-1.1.1.dmg.sig", actual / "update.sig")
        mode = "--published" if args.published else "--install-only"
        run([str(harness), str(actual), mode], env=dict(os.environ, MUSTER_UPDATE_FIXTURE=str(actual)), timeout=180)
