#!/bin/bash
# Builds dist/Muster.app with an ad-hoc signature. No Developer ID is required for local use.
# Usage: Scripts/package.sh [--dmg] [version]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="0.1.0"
MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        -h|--help) sed -n '2,3p' "$0" | sed 's/^# //'; exit 0 ;;
        *) VERSION="$arg" ;;
    esac
done

APP="dist/Muster.app"
CONTENTS="$APP/Contents"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/Muster" "$BIN/muster-hook" "$CONTENTS/MacOS/"
cp Resources/Info.plist "$CONTENTS/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
chmod +x "$CONTENTS/MacOS/Muster" "$CONTENTS/MacOS/muster-hook"

# Sign inside-out; the hook is a separate executable and must be signed too.
codesign --force --sign - "$CONTENTS/MacOS/muster-hook"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (version $VERSION, ad-hoc signed)"

if [[ "$MAKE_DMG" == "1" ]]; then
    rm -f "dist/Muster-$VERSION.dmg"
    hdiutil create -quiet -volname "Muster" -srcfolder "$APP" -ov -format UDZO "dist/Muster-$VERSION.dmg"
    echo "Built dist/Muster-$VERSION.dmg"
fi
