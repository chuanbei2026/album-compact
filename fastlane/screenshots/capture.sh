#!/bin/bash
# Capture App Store screenshots at the two sizes Apple requires, in both
# languages. Sizes come from the devices themselves — iPhone 17 Pro Max is
# 1320×2868 (the 6.9" slot) and iPad Pro 13-inch is 2064×2752 (the 13" slot).
#
#   ./fastlane/screenshots/capture.sh <path-to-demo-photos>
#
# The folder is imported into the simulator's library first: store screenshots
# should never contain a real person's photos, and a simulator with an empty
# library produces empty screens.
set -e
MEDIA="${1:?usage: capture.sh <folder-of-demo-photos>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/fastlane/screenshots"
DD="${DD:-$(mktemp -d)}"

device_udid() {
  xcrun simctl list devices available -j | python3 -c "
import json,sys
for rt, ds in json.load(sys.stdin)['devices'].items():
    for d in ds:
        if d['name'] == '$1': print(d['udid']); raise SystemExit
"
}

# route -> filename. Order is the order they appear on the product page, so the
# first one has to carry the whole idea on its own.
ROUTES=("" "deck" "duplicates" "variants" "history")
NAMES=("1_home" "2_swipe" "3_exact" "4_versions" "5_history")

for DEVICE in "iPhone 17 Pro Max" "iPad Pro 13-inch (M5)"; do
  UDID="$(device_udid "$DEVICE")"
  [ -n "$UDID" ] || { echo "!! no simulator named $DEVICE"; continue; }
  echo "== $DEVICE ($UDID)"

  xcodebuild -project "$ROOT/AlbumCompact.xcodeproj" -scheme AlbumCompact \
    -destination "id=$UDID" -derivedDataPath "$DD" build >/dev/null
  APP="$DD/Build/Products/Debug-iphonesimulator/AlbumCompact.app"

  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  xcrun simctl addmedia "$UDID" "$MEDIA"/* 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"

  # simctl's privacy grant writes a TCC row iOS ignores (auth_version 1); the
  # row a real tap produces is auth_reason 2 / auth_version 2.
  DB=~/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db
  xcrun simctl privacy "$UDID" grant photos com.xiangyang.albumcompact || true
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  sqlite3 "$DB" "update access set auth_value=2, auth_reason=2, auth_version=2 \
                 where client like '%albumcompact%';" 2>/dev/null || true
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null

  for LOC in en-US zh-Hans; do
    LANG_CODE=$([ "$LOC" = en-US ] && echo en || echo zh-Hans)
    mkdir -p "$OUT/$LOC"
    for i in "${!ROUTES[@]}"; do
      R="${ROUTES[$i]}"; N="${NAMES[$i]}"
      xcrun simctl terminate "$UDID" com.xiangyang.albumcompact 2>/dev/null || true
      ARGS=(-AppleLanguages "($LANG_CODE)")
      [ -n "$R" ] && ARGS+=(-demoRoute "$R")
      xcrun simctl launch "$UDID" com.xiangyang.albumcompact "${ARGS[@]}" >/dev/null
      # The first launch has to finish a scan before anything is on screen.
      sleep $([ "$i" -eq 0 ] && echo 62 || echo 22)
      SIZE=$(echo "$DEVICE" | grep -q iPad && echo ipad13 || echo iphone69)
      xcrun simctl io "$UDID" screenshot "$OUT/$LOC/${SIZE}_${N}.png" >/dev/null
      echo "   $LOC/${SIZE}_${N}.png"
    done
  done
done
echo "done -> $OUT"
