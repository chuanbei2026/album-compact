#!/bin/bash
# Compile the algorithm harness against the app's real Core sources.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/Tools/AlgoLab/algolab}"
swiftc -O -o "$OUT" \
  "$ROOT/AlbumCompact/Core/Model.swift" \
  "$ROOT/AlbumCompact/Core/PerceptualHasher.swift" \
  "$ROOT/AlbumCompact/Core/DuplicateFinder.swift" \
  "$ROOT/AlbumCompact/Core/VisionAnalyzer.swift" \
  "$ROOT/AlbumCompact/Core/ScreenClassifier.swift" \
  "$ROOT/AlbumCompact/Core/OnlineClassifier.swift" \
  "$ROOT/AlbumCompact/Core/DeletabilityModel.swift" \
  "$ROOT/AlbumCompact/Core/AppLabels.swift" \
  "$ROOT/Tools/AlgoLab/main.swift"
echo "built: $OUT"
