#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$(dirname "$project_dir")/Headroom Lab.app}"
swift build --package-path "$project_dir" -c release
binary_dir="$(swift build --package-path "$project_dir" -c release --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/HeadroomLab" "$app_path/Contents/MacOS/HeadroomLab"
cp "$binary_dir/DisplayGuardian" "$app_path/Contents/MacOS/DisplayGuardian"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HeadroomLab</string>
<key>CFBundleIdentifier</key><string>local.gorka.HeadroomLab</string>
<key>CFBundleName</key><string>Headroom Lab</string>
<key>CFBundleDisplayName</key><string>Headroom Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad-hoc by default. Developer ID signing is a later release gate.
signing_identity="${HEADROOM_SIGNING_IDENTITY:--}"
codesign --force --options runtime --sign "$signing_identity" "$app_path/Contents/MacOS/DisplayGuardian"
codesign --force --options runtime --sign "$signing_identity" "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built: %s\n' "$app_path"
