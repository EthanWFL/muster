#!/bin/bash
# Builds dist/Muster.app; local builds use an ad-hoc signature by default.
# Usage: Scripts/package.sh [--dmg] [--allow-unsigned-dmg] [version]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
# 默认跟最新 git tag 走，避免 plist 和 tag 两处手填错位；显式传参依旧可覆盖。
[[ -n "$VERSION" ]] || VERSION="0.1.0"
MAKE_DMG=0
ALLOW_UNSIGNED_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        --allow-unsigned-dmg) ALLOW_UNSIGNED_DMG=1 ;;
        -h|--help) sed -n '2,3p' "$0" | sed 's/^# //'; exit 0 ;;
        *) VERSION="$arg" ;;
    esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must have the form X.Y.Z" >&2
    exit 1
fi
UPDATE_PUBLIC_KEY="$(tr -d '\r\n' < Resources/UpdatePublicKey.txt)"
if [[ -n "${MUSTER_UPDATE_PUBLIC_KEY:-}" && "$MUSTER_UPDATE_PUBLIC_KEY" != "$UPDATE_PUBLIC_KEY" ]]; then
    echo "Update key override differs from the pinned Resources/UpdatePublicKey.txt" >&2
    exit 1
fi
UPDATE_KEY_FILE="${MUSTER_UPDATE_KEY_FILE:-}"
if [[ "$MAKE_DMG" == "1" && -z "$UPDATE_KEY_FILE" ]]; then
    muster_default_key="${XDG_CONFIG_HOME:-$HOME/.config}/muster/release/update-signing.key"
    if [[ -f "$muster_default_key" ]]; then UPDATE_KEY_FILE="$muster_default_key"; fi
fi
if [[ "$MAKE_DMG" == "1" && -z "$UPDATE_KEY_FILE" && "$ALLOW_UNSIGNED_DMG" != "1" ]]; then
    echo "A release DMG requires the persistent update signing key. Use --allow-unsigned-dmg only for local development." >&2
    exit 1
fi
SIGNING_IDENTITY="${MUSTER_SIGNING_IDENTITY:--}"
if [[ -n "$UPDATE_KEY_FILE" ]]; then
    swift Scripts/sign-update.swift check-private-key "$UPDATE_KEY_FILE" "$PWD"
    DERIVED_KEY="$(swift Scripts/sign-update.swift public-key "$UPDATE_KEY_FILE")"
    if [[ -n "$UPDATE_PUBLIC_KEY" && "$UPDATE_PUBLIC_KEY" != "$DERIVED_KEY" ]]; then
        echo "Signing key does not match Resources/UpdatePublicKey.txt" >&2
        exit 1
    fi
fi
swift Scripts/sign-update.swift check-key "$UPDATE_PUBLIC_KEY"

APP="dist/Muster.app"
CONTENTS="$APP/Contents"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/Muster" "$CONTENTS/MacOS/"
cp Resources/Info.plist "$CONTENTS/Info.plist"
if [[ -d "$BIN/Muster_Muster.bundle" ]]; then
    cp -R "$BIN/Muster_Muster.bundle" "$CONTENTS/Resources/"
    # Bundle.main looks up Localizable.strings in Contents/Resources/<lang>.lproj.
    for lproj in "$BIN/Muster_Muster.bundle"/*.lproj; do
        [[ -d "$lproj" ]] || continue
        name="$(basename "$lproj")"
        # SwiftPM lowercases language directories; CFBundleLocalizations expects zh-Hans.
        if [[ "$name" == "zh-hans.lproj" ]]; then name="zh-Hans.lproj"; fi
        cp -R "$lproj" "$CONTENTS/Resources/$name"
    done
fi
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MusterUpdatePublicKey string $UPDATE_PUBLIC_KEY" "$CONTENTS/Info.plist"
chmod +x "$CONTENTS/MacOS/Muster"

# Developer ID is optional; credentials and notarization are managed outside this script.
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP (version $VERSION)"

if [[ "$MAKE_DMG" == "1" ]]; then
    rm -f "dist/Muster-$VERSION.dmg" "dist/Muster-$VERSION.dmg.sig"
    # Redirect: hdiutil spawns a helper that can inherit the caller's stdout and keep a pipe open.
    hdiutil create -quiet -volname "Muster" -srcfolder "$APP" -ov -format UDZO "dist/Muster-$VERSION.dmg" >/dev/null 2>&1
    echo "Built dist/Muster-$VERSION.dmg"
    if [[ -n "$UPDATE_KEY_FILE" ]]; then
        swift Scripts/sign-update.swift sign "dist/Muster-$VERSION.dmg" "$UPDATE_KEY_FILE" "$UPDATE_PUBLIC_KEY" "dist/Muster-$VERSION.dmg.sig"
        swift Scripts/sign-update.swift verify "dist/Muster-$VERSION.dmg" "dist/Muster-$VERSION.dmg.sig" "$UPDATE_PUBLIC_KEY"
        echo "Verified dist/Muster-$VERSION.dmg.sig"
    else
        echo "Development-only unsigned DMG: it must not be published as an official release."
    fi
    (cd dist && shasum -a 256 "Muster-$VERSION.dmg" > "Muster-$VERSION.sha256")
fi
