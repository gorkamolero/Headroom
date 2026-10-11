#!/bin/bash
set -euo pipefail
umask 077
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
source_dir="$project_dir/Tests/Integration"
harness_dir="${1:-$project_dir/Evidence/boost-telemetry-audit}"
swift build --package-path "$project_dir" -c release --triple arm64-apple-macosx13.0 --product Headroom
swift build --package-path "$project_dir" -c release --triple arm64-apple-macosx13.0 --product DisplayGuardian
binary_dir="$(swift build --package-path "$project_dir" -c release --triple arm64-apple-macosx13.0 --show-bin-path)"
app="$harness_dir/BoostTelemetryAudit.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
common=(-target arm64-apple-macosx13.0 -I "$binary_dir")
swiftc "${common[@]}" -o "$app/Contents/MacOS/BoostTelemetryAudit" \
  "$source_dir/BoostTelemetryAudit.swift" \
  "$project_dir/Sources/Headroom/BoostSession.swift" \
  "$project_dir/Sources/HeadroomLab/EDRPatch.swift" \
  "$project_dir/Sources/Headroom/Compatibility/NormalBrightnessReader.swift" \
  "$project_dir/Sources/Headroom/Compatibility/DisplayLuminanceReader.swift" \
  "$project_dir/Sources/Headroom/Compatibility/CoreBrightnessLuminanceReader.swift" \
  "$binary_dir/DisplayCore.o" "$binary_dir/DisplayActivation.o"
swiftc "${common[@]}" -o "$harness_dir/Watchdog" \
  "$source_dir/Watchdog.swift" \
  "$project_dir/Sources/Headroom/Compatibility/NormalBrightnessReader.swift" \
  "$binary_dir/DisplayCore.o"
cp "$binary_dir/DisplayGuardian" "$app/Contents/MacOS/DisplayGuardian"
ditto "$binary_dir/HeadroomPrototype_DisplayActivation.bundle" "$app/Contents/Resources/HeadroomPrototype_DisplayActivation.bundle"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BoostTelemetryAudit</string>
<key>CFBundleIdentifier</key><string>local.gorka.HeadroomBoostTelemetryAudit</string>
<key>CFBundleName</key><string>Headroom Bounded Telemetry Audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/DisplayGuardian"
codesign --force --sign - "$app"
codesign --force --sign - "$harness_dir/Watchdog"
codesign --verify --deep --strict "$app"
printf 'Built bounded telemetry audit: %s\n' "$app/Contents/MacOS/BoostTelemetryAudit"
printf 'External watchdog: %s\n' "$harness_dir/Watchdog"
printf 'No display settings have been changed. Run only through Watchdog after quitting Headroom and Lunar.\n'
