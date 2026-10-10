#!/bin/bash
# Explicit operator action: this script uploads the signed app to Apple.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/notarize-release.sh /path/to/Headroom.app KEYCHAIN_PROFILE [output-directory]

Requires an existing Developer ID signed app and a notarytool keychain profile.
Uploads that app to Apple, requires status Accepted, staples and validates its
notarization ticket, then creates the checked distribution ZIP. No credentials
are stored in this repository. The supplied app is modified only by stapling.
USAGE
}
[[ "${1:-}" != --help && "${1:-}" != -h ]] || { usage; exit 0; }
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$1"
profile="$2"
output_dir="${3:-$project_dir/dist}"
[[ -d "$app_path" && "$app_path" == *.app ]] || { printf 'Missing .app bundle: %s\n' "$app_path" >&2; exit 2; }
[[ -n "$profile" ]] || { printf 'A keychain profile is required.\n' >&2; exit 2; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" == local.gorka.Headroom ]] || { printf 'Expected a Headroom app bundle.\n' >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
for signed_item in "$app_path" "$app_path/Contents/MacOS/DisplayGuardian"; do
    signature="$(codesign -d --verbose=4 "$signed_item" 2>&1)"
    [[ "$signature" == *'Authority=Developer ID Application:'* && "$signature" == *'Timestamp='* && "$signature" == *'runtime'* ]] || {
        printf 'Refusing upload: requires Developer ID, a secure timestamp, and hardened runtime.\n' >&2; exit 1;
    }
done
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
record_dir="$(mktemp -d "$output_dir/notarization.XXXXXX")"
submission_zip="$record_dir/submission.zip"
# Keep submission evidence on failure; the upload archive is only a staging file.
trap '/bin/rm -f -- "$submission_zip"' EXIT
ditto -c -k --keepParent "$app_path" "$submission_zip"
printf 'Submitting signed app to Apple. Results: %s\n' "$record_dir"
xcrun notarytool submit "$submission_zip" --keychain-profile "$profile" --wait --output-format json > "$record_dir/submission.json"
status="$(plutil -extract status raw -o - "$record_dir/submission.json")"
submission_id="$(plutil -extract id raw -o - "$record_dir/submission.json")"
if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$record_dir/log.json" || true
    printf 'Notarization was not accepted (%s). See %s\n' "$status" "$record_dir" >&2
    exit 1
fi
xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$record_dir/log.json"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
"$project_dir/scripts/package-release.sh" --notarized "$app_path" "$output_dir"
printf 'Notarization evidence: %s\n' "$record_dir"
