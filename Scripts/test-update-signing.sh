#!/usr/bin/env bash
# Exercise release signing with a disposable test key; never uses a release credential.
set -euo pipefail
cd "$(dirname "$0")/.."
muster_signing_test_dir="$(mktemp -d)"
trap 'rm -rf "$muster_signing_test_dir"' EXIT
muster_test_public_key="$(swift Scripts/sign-update.swift generate-key "$muster_signing_test_dir/test.key")"
swift Scripts/sign-update.swift check-key "$muster_test_public_key"
printf 'test update payload' > "$muster_signing_test_dir/payload"
swift Scripts/sign-update.swift sign "$muster_signing_test_dir/payload" "$muster_signing_test_dir/test.key" "$muster_test_public_key" "$muster_signing_test_dir/payload.sig"
swift Scripts/sign-update.swift verify "$muster_signing_test_dir/payload" "$muster_signing_test_dir/payload.sig" "$muster_test_public_key"
printf 'tampered payload' > "$muster_signing_test_dir/payload"
if swift Scripts/sign-update.swift verify "$muster_signing_test_dir/payload" "$muster_signing_test_dir/payload.sig" "$muster_test_public_key" > /dev/null 2>&1; then
    echo "Tampered payload was accepted" >&2
    exit 1
fi
if swift Scripts/sign-update.swift generate-key "$muster_signing_test_dir/test.key" > /dev/null 2>&1; then
    echo "An existing key was overwritten" >&2
    exit 1
fi
echo "Update signing round trip, tamper rejection and key preservation passed."
