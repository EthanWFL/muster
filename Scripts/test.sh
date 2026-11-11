#!/usr/bin/env bash
# 在只装了 Command Line Tools（没有 Xcode）的机器上跑 swift test。
# CLT 自带 Swift Testing，但 SwiftPM 不会自动加 -F 和 rpath，这里手动补上。
# 有完整 Xcode 时这些参数无害，照常可用。
set -euo pipefail

DEV=/Library/Developer/CommandLineTools/Library/Developer
F="$DEV/Frameworks"
L="$DEV/usr/lib"

cd "$(dirname "$0")/.."
exec swift test \
  -Xswiftc -F -Xswiftc "$F" \
  -Xlinker -F -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$L" \
  "$@"
