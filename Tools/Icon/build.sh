#!/bin/bash
# Redraw the app icon. The icon is vector-drawn in code rather than a flat PNG so
# it can be re-rendered at any size and tweaked without a design tool.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/Tools/Icon/out}"
mkdir -p "$OUT"
swiftc -O -o "$OUT/genicon" "$ROOT/Tools/Icon/GenerateIcon.swift"
"$OUT/genicon" "$OUT"
cp "$OUT/vA_1024.png" "$ROOT/AlbumCompact/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
echo "icon updated from variant A"
