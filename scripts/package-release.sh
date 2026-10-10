#!/bin/bash
# Produces a minimal, checked ZIP; never publishes or installs anything.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/package-release.sh --beta [output-directory]
       HEADROOM_SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' \
         scripts/package-release.sh --developer-id [output-directory]
       scripts/package-release.sh --notarized /path/to/Headroom.app [output-directory]

--beta          Build and package an explicitly labelled ad-hoc community beta.
--developer-id  Build a signed candidate only; notarize it before packaging.
--notarized     Package an already stapled app after signature and Gatekeeper checks.

Outputs refuse to overwrite an earlier build. No source, logs, or recovery data
are included in the app archive. Beta requires no Apple account or network service.
USAGE
}

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-}"
case "$mode" in
    --beta|--developer-id|--notarized) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
source_app=""
if [[ "$mode" == --notarized ]]; then
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    source_app="$1"
    shift
else
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
fi
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
if [[ "$mode" == --developer-id ]]; then
    app_path="$output_dir/Headroom.app"
    "$project_dir/scripts/build-menu-app.sh" --developer-id "$app_path"
    printf 'Signed candidate prepared. Notarize with:\n  scripts/notarize-release.sh "%s" YOUR_KEYCHAIN_PROFILE "%s"\n' "$app_path" "$output_dir"
    exit 0
fi

stage="$(mktemp -d "$output_dir/.headroom-package.XXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT
if [[ "$mode" == --beta ]]; then
    source_app="$stage/Headroom.app"
    "$project_dir/scripts/build-menu-app.sh" --beta "$source_app"
    channel="community-beta"
else
    [[ -d "$source_app" && "$source_app" == *.app ]] || { printf 'Missing .app bundle: %s\n' "$source_app" >&2; exit 2; }
    channel="notarized"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == local.gorka.Headroom ]] || { printf 'Expected a Headroom app bundle.\n' >&2; exit 1; }
    for signed_item in "$source_app" "$source_app/Contents/MacOS/DisplayGuardian"; do
        signature="$(codesign -d --verbose=4 "$signed_item" 2>&1)"
        [[ "$signature" == *'Authority=Developer ID Application:'* && "$signature" == *'Timestamp='* && "$signature" == *'runtime'* ]] || {
            printf 'This is not a Developer ID signed app with a secure timestamp and hardened runtime.\n' >&2; exit 1;
        }
    done
    xcrun stapler validate "$source_app"
    spctl --assess --type execute --verbose=2 "$source_app"
fi
codesign --verify --deep --strict "$source_app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid release version.\n' >&2; exit 1; }
[[ "$(lipo -archs "$source_app/Contents/MacOS/Headroom")" == arm64 ]] || { printf 'This release workflow expects arm64.\n' >&2; exit 1; }
archive_name="Headroom-$version-$channel-arm64"
archive_path="$output_dir/$archive_name.zip"
checksum_path="$archive_path.sha256"
[[ ! -e "$archive_path" && ! -e "$checksum_path" ]] || { printf 'Release files already exist: %s\n' "$archive_path" >&2; exit 1; }
payload="$stage/$archive_name"
mkdir "$payload"
ditto "$source_app" "$payload/Headroom.app"
cat > "$payload/READ-ME.txt" <<READ_ME
Headroom $version — $channel
By Gorka Molero · https://github.com/Gorkamolero/Headroom

REQUIREMENTS
Apple silicon Mac, macOS 13 or later, and a compatible display with HDR/EDR
headroom. Actual compatibility varies by Mac, display, macOS version, and settings.

INSTALL
Move Headroom.app into Applications, then open it. Its black-sun control appears
in the menu bar. It starts with boost OFF. Enable a supported display and move
its slider. Disable boost or quit Headroom to restore its saved display settings.

HOW IT WORKS
A tiny, paused HDR carrier requests EDR headroom. A separate recovery helper
scales the display's RGB transfer tables from a saved baseline. This changes
ordinary desktop appearance without screen recording or continuous video playback.

PRIVACY
No account, analytics, screen capture, or app network connection. The app stores
preferences and temporary recovery data locally. No administrator access is needed.

SAFETY AND LIMITS
This is experimental software. Transfer-table values above 1 are outside Apple's
documented range and may behave differently across systems. Tests on the developer's
Mac verified restoration, including several crash cases; they cannot guarantee
compatibility or that nothing can go wrong. Extra brightness can use more power.
The slider is a scaling factor, not a measured brightness multiplier or nits value.
If something looks wrong, turn boost off or quit; reopen Headroom for recovery.

Source, method, test scope, and issue reporting:
https://github.com/Gorkamolero/Headroom
READ_ME
if [[ "$mode" == --beta ]]; then
    cat >> "$payload/READ-ME.txt" <<'BETA'

SIGNING STATUS
This community beta has an ad-hoc signature. It is not Developer ID signed or
notarized by Apple. macOS may prevent a downloaded copy from opening. No system
security settings need to be disabled; a Developer ID notarized release is pending.
BETA
else
    cat >> "$payload/READ-ME.txt" <<'SIGNED'

SIGNING STATUS
Developer ID signed, accepted by Apple's notarization service, and ticket stapled.
Notarization checks distribution security; it does not certify display compatibility.
SIGNED
fi
# Package and extract again to verify exactly what recipients receive.
ditto -c -k --keepParent "$payload" "$stage/$archive_name.zip"
mkdir "$stage/verify"
ditto -x -k "$stage/$archive_name.zip" "$stage/verify"
verified_app="$stage/verify/$archive_name/Headroom.app"
codesign --verify --deep --strict "$verified_app"
if [[ "$mode" == --notarized ]]; then
    xcrun stapler validate "$verified_app"
    spctl --assess --type execute --verbose=2 "$verified_app"
fi
mv "$stage/$archive_name.zip" "$archive_path"
(cd "$output_dir" && shasum -a 256 "$archive_name.zip" > "$archive_name.zip.sha256")
printf 'Packaged: %s\nChecksum: %s\n' "$archive_path" "$checksum_path"
