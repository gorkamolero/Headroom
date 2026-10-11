#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
swift build --package-path "$project_dir" -c release --triple arm64-apple-macosx13.0 --product Headroom
binary_dir="$(swift build --package-path "$project_dir" -c release --triple arm64-apple-macosx13.0 --show-bin-path)"
app="$project_dir/Evidence/nits-build17/NitsHUDCheck.app"
mkdir -p "$app/Contents/MacOS"
swiftc -target arm64-apple-macosx13.0 -I "$binary_dir" \
  "$project_dir/Tests/Integration/LuminanceHUD.swift" \
  "$project_dir/Sources/Headroom/BrightnessHUD.swift" \
  "$project_dir/Sources/Headroom/Compatibility/DisplayLuminanceReader.swift" \
  "$binary_dir/DisplayCore.o" -o "$app/Contents/MacOS/NitsHUDCheck"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NitsHUDCheck</string>
<key>CFBundleIdentifier</key><string>local.gorka.HeadroomNitsCheck</string>
<key>CFBundleName</key><string>Headroom Nits Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'Built read-only nits HUD check: %s\n' "$app"
