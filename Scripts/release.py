#!/usr/bin/env python3
"""Build and publish a verified signed release from an already-pushed, CI-passing tag."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def output(arguments):
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def publish(version, notes):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Version must be X.Y.Z")
    if output(["git", "status", "--porcelain"]):
        raise ValueError("Commit the reviewed release changes before publishing")
    head = output(["git", "rev-parse", "HEAD"])
    if output(["git", "rev-parse", version + "^{}"]) != head:
        raise ValueError("Release tag must identify the current commit")
    remote = output(["git", "ls-remote", "origin", "refs/tags/" + version, "refs/tags/" + version + "^{}"])
    if not any(line.split()[0] == head for line in remote.splitlines()):
        raise ValueError("Push the matching tag before publishing")
    repo = output(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])
    runs = json.loads(output(["gh", "run", "list", "--repo", repo, "--workflow", "ci.yml", "--event", "push",
        "--commit", head, "--json", "headBranch,status,conclusion", "--limit", "30"]))
    if not any(r["headBranch"] == version and r["status"] == "completed" and r["conclusion"] == "success" for r in runs):
        raise ValueError("The release tag's CI must pass before publishing")
    existing = subprocess.run(["gh", "release", "view", version, "--repo", repo], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if existing.returncode == 0:
        raise ValueError("This release already exists; it will not be overwritten")
    if not notes.is_file():
        raise ValueError("Release notes file not found")
    subprocess.run(["bash", "Scripts/package.sh", "--dmg", version], cwd=ROOT, check=True)
    subprocess.run([sys.executable, "Scripts/verify-release.py", version], cwd=ROOT, check=True)
    assets = [str(ROOT / "dist" / ("Muster-" + version + suffix)) for suffix in [".dmg", ".dmg.sig", ".sha256"]]
    subprocess.run(["gh", "release", "create", version, *assets, "--repo", repo, "--verify-tag", "--latest",
        "--title", "Muster " + version, "--notes-file", str(notes.resolve())], cwd=ROOT, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--notes", type=Path, required=True)
    args = parser.parse_args()
    try:
        publish(args.version, args.notes)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("Release stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
