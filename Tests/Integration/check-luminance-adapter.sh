#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
output_dir="$project_dir/Evidence/luminance-adapter"
mkdir -p "$output_dir"
shared_sources=(
  "$project_dir/Sources/Headroom/Compatibility/DisplayLuminanceReader.swift"
  "$project_dir/Tests/Integration/LuminanceAdapterValidation.swift"
)
swiftc -O "${shared_sources[@]}" \
  "$project_dir/Sources/Headroom/Compatibility/CoreBrightnessLuminanceReader.swift" \
  -o "$output_dir/LuminanceAdapterValidation"
swiftc -O -D HEADROOM_LUMINANCE_FORCE_FALLBACK "${shared_sources[@]}" \
  "$project_dir/Tests/Integration/LuminanceUnavailableProvider.swift" \
  -o "$output_dir/LuminanceFallbackValidation"
"$output_dir/LuminanceAdapterValidation" "$@" > "$output_dir/adapter-check.json"
"$output_dir/LuminanceFallbackValidation" "$@" > "$output_dir/fallback-check.json"
printf 'Read-only adapter and forced-fallback checks passed. Reports: %s\n' "$output_dir"
