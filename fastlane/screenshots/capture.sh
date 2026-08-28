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
#
# ⚠️  This script ERASES the two devices it uses (iPhone 17 Pro Max and
# iPad Pro 13-inch). Erase is device-wide: it removes every app and sandbox on
# that simulator, not just this one. If another session is working on either
# device, coordinate first. No other simulator is touched.
set -e
MEDIA="${1:?usage: capture.sh <folder-of-demo-photos>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/fastlane/screenshots"
DD="${DD:-$(mktemp -d)}"

# The status bar is visible in every screenshot and cannot be fixed afterwards.
# Without an override you get the wall-clock time and whatever battery level the
# device happens to be at, which looks unfinished on a product page; 9:41 is
# Apple's own convention. batteryState is "discharging" at 100%, not "charged" —
# "charged" draws the green bolt.
#
# It does not survive a reboot, and the language switch below reboots, so this
# has to be re-applied after every boot rather than set once.
pin_status_bar() {
  xcrun simctl status_bar "$1" override \
    --time "9:41" --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 \
    --wifiMode active --wifiBars 3 --dataNetwork wifi 2>/dev/null || true
}

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
# The fifth slot is "moments", not "history".
#
# History is empty on a fresh device, and the only way to fill it is the DEBUG
# -seedHistory flag, which fabricates 16 weeks of cleanups on a 78 GB / 41,800
# photo library. Putting that on a product page would present invented usage as
# real. "Same moment" has genuine content and is the actual differentiator:
# every competitor sweeps bursts automatically, this one hands them back.
ROUTES=("" "deck" "duplicates" "variants" "moments")
NAMES=("1_home" "2_swipe" "3_exact" "4_versions" "5_moments")

for DEVICE in "iPhone 17 Pro Max" "iPad Pro 13-inch (M5)"; do
  UDID="$(device_udid "$DEVICE")"
  [ -n "$UDID" ] || { echo "!! no simulator named $DEVICE"; continue; }
  echo "== $DEVICE ($UDID)"

  # Erase first, so the script is safe to re-run.
  #
  # simctl addmedia is cumulative and survives a failed run: three attempts
  # earlier left three copies of every photo in the library (79 x 3 + 6 stock
  # wallpapers = 243), which inflated "exact duplicates" from 7 groups to 59 and
  # then starved the category counts, because a photo already claimed by the
  # duplicate pass never reaches a category. Screenshots taken from that state
  # are worse than useless — they look plausible.
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl erase "$UDID" || { echo "!! erase failed for $DEVICE"; exit 1; }

  # Boot BEFORE building. xcodebuild cannot resolve a destination on a
  # shut-down device — it fails with "Supported platforms for the buildables in
  # the current scheme is empty", and every later step then works on an empty
  # app path, which is how an earlier run of this script exited 0 having
  # produced no screenshots at all.
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null

  xcodebuild -project "$ROOT/AlbumCompact.xcodeproj" -scheme AlbumCompact \
    -destination "id=$UDID" -derivedDataPath "$DD" build >/dev/null || {
      echo "!! build failed for $DEVICE"; exit 1; }
  APP="$DD/Build/Products/Debug-iphonesimulator/AlbumCompact.app"
  [ -d "$APP" ] || { echo "!! no app at $APP"; exit 1; }

  xcrun simctl addmedia "$UDID" "$MEDIA"/* 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP" || { echo "!! install failed"; exit 1; }

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

    # -AppleLanguages at launch only switches the APP. The status bar belongs to
    # the system, so on iPad the date rendered in the device language — English
    # screenshots carried "8月28日周五". The device language has to change too.
    #
    # `simctl spawn <dev> defaults write` does NOT do it (verified: the value
    # never lands). Writing the host-side plist while the device is shut down
    # and then booting does — verified by cropping the status bar, which came
    # back "9:41 AM  Fri Aug 28".
    GP=~/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Preferences/.GlobalPreferences.plist
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    plutil -replace AppleLanguages -json "[\"$LANG_CODE\"]" "$GP" 2>/dev/null || true
    plutil -replace AppleLocale -string \
      "$([ "$LOC" = en-US ] && echo en_US || echo zh_Hans_CN)" "$GP" 2>/dev/null || true
    xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    pin_status_bar "$UDID"

    for i in "${!ROUTES[@]}"; do
      R="${ROUTES[$i]}"; N="${NAMES[$i]}"
      xcrun simctl terminate "$UDID" com.xiangyang.albumcompact 2>/dev/null || true
      ARGS=(-AppleLanguages "($LANG_CODE)")
      [ -n "$R" ] && ARGS+=(-demoRoute "$R")
      # SpringBoard can refuse the first launch after an install or a reboot
      # (FBSOpenApplicationServiceErrorDomain code=1, "denied by service
      # delegate") while it is still registering the app. It clears in a few
      # seconds, so retry rather than sleeping blindly.
      for try in 1 2 3 4 5; do
        xcrun simctl launch "$UDID" com.xiangyang.albumcompact "${ARGS[@]}" \
          >/dev/null 2>&1 && break
        [ "$try" = 5 ] && { echo "!! launch failed for $LOC/$N"; exit 1; }
        sleep 4
      done
      # The first launch has to finish a scan before anything is on screen.
      sleep $([ "$i" -eq 0 ] && echo 62 || echo 22)
      SIZE=$(echo "$DEVICE" | grep -q iPad && echo ipad13 || echo iphone69)
      xcrun simctl io "$UDID" screenshot "$OUT/$LOC/${SIZE}_${N}.png" >/dev/null
      [ -s "$OUT/$LOC/${SIZE}_${N}.png" ] \
        || { echo "!! screenshot missing: $LOC/${SIZE}_${N}.png"; exit 1; }
      echo "   $LOC/${SIZE}_${N}.png  ($(du -h "$OUT/$LOC/${SIZE}_${N}.png" | cut -f1))"
    done
  done
done
echo "done -> $OUT"
