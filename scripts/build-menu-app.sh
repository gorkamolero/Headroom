#!/bin/bash
# Assemble a fresh app bundle. Existing destinations are never replaced.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/build-menu-app.sh --beta [output.app]
       scripts/build-menu-app.sh --local [output.app]
       HEADROOM_SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' \
         scripts/build-menu-app.sh --developer-id [output.app]

--beta          Ad-hoc signature for local testing; not notarized.
--local         Reuse a certificate-bound local identity; not notarized.
--developer-id  Require a Developer ID Application identity and secure timestamp.

HEADROOM_SIGNING_KEYCHAIN optionally selects an existing keychain for --local.
For --local, HEADROOM_SIGNING_IDENTITY overrides the fingerprint saved in
~/Library/Application Support/Headroom Development/signing-identity.
Builds Apple silicon (arm64), with macOS 13 as the deployment target.
USAGE
}

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-}"
case "$mode" in
    --beta|--local|--developer-id) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }
app_path="${1:-$project_dir/dist/Headroom.app}"
[[ "$app_path" == *.app ]] || { printf 'Output must end in .app\n' >&2; exit 2; }
[[ ! -e "$app_path" && ! -L "$app_path" ]] || { printf 'Destination already exists: %s\n' "$app_path" >&2; exit 1; }
[[ -f "$project_dir/Assets/AppIcon.icns" ]] || { printf 'Missing Assets/AppIcon.icns\n' >&2; exit 1; }

signing_identity="-"
sign_args=(--force --options runtime)
if [[ "$mode" == --developer-id ]]; then
    signing_identity="${HEADROOM_SIGNING_IDENTITY:-}"
    [[ "$signing_identity" == 'Developer ID Application: '* ]] || {
        printf 'Set HEADROOM_SIGNING_IDENTITY to the full Developer ID Application identity. No ad-hoc fallback is permitted.\n' >&2
        exit 1
    }
    security find-identity -v -p codesigning | /usr/bin/grep -F -- "\"$signing_identity\"" >/dev/null || {
        printf 'The requested valid signing identity is not available in the keychain.\n' >&2
        exit 1
    }
    sign_args+=(--timestamp)
elif [[ "$mode" == --local ]]; then
    local_identity_config="$HOME/Library/Application Support/Headroom Development/signing-identity"
    if [[ "${HEADROOM_SIGNING_IDENTITY+x}" == x ]]; then
        # Explicit values, including empty or invalid ones, never fall back.
        signing_identity="$HEADROOM_SIGNING_IDENTITY"
    elif [[ -f "$local_identity_config" ]]; then
        # This file contains data only. Never source it as shell code.
        signing_identity="$(cat "$local_identity_config")"
        # Permit a single final newline, but no ignored bytes or extra lines.
        if ! printf '%s\n' "$signing_identity" | cmp -s - "$local_identity_config" && \
           ! printf '%s' "$signing_identity" | cmp -s - "$local_identity_config"; then
            printf 'The saved local signing identity must contain only one 40-hex certificate fingerprint.\n' >&2
            exit 1
        fi
    else
        signing_identity=""
    fi
    [[ "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]] || {
        printf 'Set HEADROOM_SIGNING_IDENTITY or save the exact 40-hex certificate fingerprint in %s. No ad-hoc fallback is permitted.\n' "$local_identity_config" >&2
        exit 1
    }
    signing_identity="$(printf '%s' "$signing_identity" | tr '[:lower:]' '[:upper:]')"
    identity_keychain_args=(-p codesigning)
    if [[ -n "${HEADROOM_SIGNING_KEYCHAIN:-}" ]]; then
        [[ -f "$HEADROOM_SIGNING_KEYCHAIN" ]] || {
            printf 'HEADROOM_SIGNING_KEYCHAIN must name an existing keychain file.\n' >&2
            exit 1
        }
        identity_keychain_args+=("$HEADROOM_SIGNING_KEYCHAIN")
        sign_args+=(--keychain "$HEADROOM_SIGNING_KEYCHAIN")
    fi
    # An exact self-signed certificate can establish local code identity without
    # adding a globally trusted root. The later checks verify its signature and DR.
    local_identities="$(security find-identity "${identity_keychain_args[@]}")"
    printf '%s\n' "$local_identities" | /usr/bin/grep -E "^[[:space:]]*[0-9]+\\) $signing_identity \"" >/dev/null || {
        printf 'The requested local signing identity and private key are not available.\n' >&2
        exit 1
    }
    sign_args+=(--timestamp=none)
else
    # An inherited identity must not accidentally upload a timestamp request.
    sign_args+=(--timestamp=none)
fi

build_args=(--package-path "$project_dir" -c release --triple arm64-apple-macosx13.0)
swift build "${build_args[@]}" --product Headroom
swift build "${build_args[@]}" --product DisplayGuardian
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"

mkdir -p "$(dirname "$app_path")"
app_parent="$(cd "$(dirname "$app_path")" && pwd)"
app_path="$app_parent/$(basename "$app_path")"
stage="$(mktemp -d "$app_parent/.headroom-build.XXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT
staged_app="$stage/Headroom.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/Headroom" "$staged_app/Contents/MacOS/Headroom"
cp "$binary_dir/DisplayGuardian" "$staged_app/Contents/MacOS/DisplayGuardian"
ditto --norsrc --noextattr "$binary_dir/HeadroomPrototype_DisplayActivation.bundle" "$staged_app/Contents/Resources/HeadroomPrototype_DisplayActivation.bundle"
cp "$project_dir/Assets/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
for status_icon in StatusOff StatusOn; do
    cp "$project_dir/Assets/$status_icon.pdf" "$staged_app/Contents/Resources/$status_icon.pdf"
done
cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleExecutable</key><string>Headroom</string>
<key>CFBundleIdentifier</key><string>local.gorka.Headroom</string>
<key>CFBundleName</key><string>Headroom</string>
<key>CFBundleDisplayName</key><string>Headroom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>21</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Gorka Molero.</string>
</dict></plist>
PLIST
plutil -lint "$staged_app/Contents/Info.plist"

# Keep the release self-contained: only system libraries and the bundled carrier.
for executable in Headroom DisplayGuardian; do
    binary="$staged_app/Contents/MacOS/$executable"
    [[ "$(lipo -archs "$binary")" == arm64 ]] || { printf 'Unexpected architecture: %s\n' "$executable" >&2; exit 1; }
    dependencies="$(otool -L "$binary" | tail -n +2 | awk '{print $1}')"
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*) ;;
            *) printf 'Non-system dependency in %s: %s\n' "$executable" "$dependency" >&2; exit 1 ;;
        esac
    done <<< "$dependencies"
done
carrier_bundle="$staged_app/Contents/Resources/HeadroomPrototype_DisplayActivation.bundle"
[[ -s "$carrier_bundle/Contents/Resources/black-hlg.mov" || -s "$carrier_bundle/black-hlg.mov" ]] || {
    printf 'The bundled HDR carrier is missing.\n' >&2; exit 1;
}
if [[ "$mode" == --local ]]; then
    for signed_identifier in local.gorka.Headroom.DisplayGuardian local.gorka.Headroom; do
        signed_item="$staged_app"
        [[ "$signed_identifier" != local.gorka.Headroom.DisplayGuardian ]] || signed_item="$staged_app/Contents/MacOS/DisplayGuardian"
        local_requirement="identifier \"$signed_identifier\" and certificate leaf = H\"$signing_identity\""
        codesign "${sign_args[@]}" --sign "$signing_identity" --identifier "$signed_identifier" \
            --requirements "=designated => $local_requirement" "$signed_item"
        codesign --verify --strict --test-requirement "=$local_requirement" "$signed_item"
        # Reject any unexpected default, code-hash-only, or identifier-only DR.
        # Comparing the full canonical expression also rejects weaker OR clauses.
        actual_requirement="$(codesign -d -r- "$signed_item" 2>&1 | sed -n 's/^designated => //p' | tr '[:upper:]' '[:lower:]')"
        expected_requirement="$(printf '%s' "$local_requirement" | tr '[:upper:]' '[:lower:]')"
        [[ "$actual_requirement" == "$expected_requirement" ]] || {
            printf 'Local certificate-bound designated requirement verification failed: %s\n' "$signed_item" >&2
            exit 1
        }
    done
else
    codesign "${sign_args[@]}" --sign "$signing_identity" "$staged_app/Contents/MacOS/DisplayGuardian"
    codesign "${sign_args[@]}" --sign "$signing_identity" "$staged_app"
fi
codesign --verify --deep --strict --verbose=2 "$staged_app"
if [[ "$mode" == --developer-id ]]; then
    for signed_item in "$staged_app" "$staged_app/Contents/MacOS/DisplayGuardian"; do
        signature="$(codesign -d --verbose=4 "$signed_item" 2>&1)"
        [[ "$signature" == *'Authority=Developer ID Application:'* && "$signature" == *'Timestamp='* && "$signature" == *'runtime'* ]] || {
            printf 'Developer ID signature verification failed: %s\n' "$signed_item" >&2; exit 1;
        }
    done
fi
# mv cannot replace an app unexpectedly if another build won the race.
[[ ! -e "$app_path" && ! -L "$app_path" ]] || { printf 'Destination appeared during build: %s\n' "$app_path" >&2; exit 1; }
mv "$staged_app" "$app_path"
printf 'Built: %s\n' "$app_path"
if [[ "$mode" == --beta ]]; then
    printf 'Signature: ad-hoc community beta; not notarized.\n'
elif [[ "$mode" == --local ]]; then
    printf 'Signature: persistent local certificate identity; not Developer ID signed or notarized.\n'
else
    printf 'Signature: Developer ID; notarization is still required before distribution.\n'
fi
