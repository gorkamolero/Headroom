#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
output_dir="$project_dir/Evidence/luminance-adapter"
mkdir -p "$output_dir"
swiftc -O -D HEADROOM_LUMINANCE_FORCE_FALLBACK \
  "$project_dir/Sources/Headroom/Compatibility/DisplayLuminanceReader.swift" \
  "$project_dir/Tests/Integration/LuminanceUnavailableProvider.swift" \
  "$project_dir/Tests/Integration/LuminanceCacheValidation.swift" \
  -o "$output_dir/LuminanceCacheValidation"
"$output_dir/LuminanceCacheValidation" > "$output_dir/cache-check.json"
printf 'Cached-reader stall, freshness, queue-bound and lifetime checks passed: %s\n' "$output_dir/cache-check.json"
