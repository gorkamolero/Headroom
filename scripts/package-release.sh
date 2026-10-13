#!/bin/bash
# Produces a minimal, checked ZIP; never publishes or installs anything.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/package-release.sh --beta [output-directory]
       scripts/package-release.sh --community-signed /path/to/Headroom.app [output-directory]
       HEADROOM_SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' \
         scripts/package-release.sh --developer-id [output-directory]
       scripts/package-release.sh --notarized /path/to/Headroom.app [output-directory]

--beta          Build and package an explicitly labelled ad-hoc community beta.
--community-signed  Package an existing app signed with the persistent community
                    certificate; require its configured fingerprint and exact identity.
--developer-id  Build a signed candidate only; notarize it before packaging.
--notarized     Package an already stapled app after signature and Gatekeeper checks.

Outputs refuse to overwrite an earlier build. No source, logs, or recovery data
are included in the app archive. Beta requires no Apple account or network service.
For --community-signed, HEADROOM_SIGNING_IDENTITY overrides the fingerprint in
~/Library/Application Support/Headroom Development/signing-identity. No keychain
access, signing, trust changes, rebuild, or notarization is performed in this mode.
USAGE
}

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-}"
case "$mode" in
    --beta|--community-signed|--developer-id|--notarized) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
source_app=""
if [[ "$mode" == --notarized || "$mode" == --community-signed ]]; then
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    source_app="$1"
    shift
else
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
fi

# Only the public certificate fingerprint is needed to check an existing app.
# Never load a keychain, export a private key, or treat this data as shell code.
community_fingerprint=""
if [[ "$mode" == --community-signed ]]; then
    identity_config="$HOME/Library/Application Support/Headroom Development/signing-identity"
    if [[ "${HEADROOM_SIGNING_IDENTITY+x}" == x ]]; then
        community_fingerprint="$HEADROOM_SIGNING_IDENTITY"
    elif [[ -f "$identity_config" ]]; then
        community_fingerprint="$(cat "$identity_config")"
        if ! printf '%s\n' "$community_fingerprint" | cmp -s - "$identity_config" && \
           ! printf '%s' "$community_fingerprint" | cmp -s - "$identity_config"; then
            printf 'The saved signing identity must contain one 40-hex certificate fingerprint only.\n' >&2
            exit 1
        fi
    fi
    [[ "$community_fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || {
        printf 'Set HEADROOM_SIGNING_IDENTITY or save the exact 40-hex certificate fingerprint in %s.\n' "$identity_config" >&2
        exit 1
    }
    community_fingerprint="$(printf '%s' "$community_fingerprint" | tr '[:lower:]' '[:upper:]')"
fi

verify_community_identity() {
    local app="$1" identifier item requirement actual expected
    for identifier in local.gorka.Headroom local.gorka.Headroom.DisplayGuardian; do
        item="$app"
        [[ "$identifier" != local.gorka.Headroom.DisplayGuardian ]] || item="$app/Contents/MacOS/DisplayGuardian"
        requirement="identifier \"$identifier\" and certificate leaf = H\"$community_fingerprint\""
        codesign --verify --strict --test-requirement "=$requirement" "$item"
        actual="$(codesign -d -r- "$item" 2>&1 | sed -n 's/^designated => //p' | tr '[:upper:]' '[:lower:]')"
        expected="$(printf '%s' "$requirement" | tr '[:upper:]' '[:lower:]')"
        [[ "$actual" == "$expected" ]] || {
            printf 'Expected an exact certificate-bound designated requirement: %s\n' "$item" >&2
            exit 1
        }
    done
}

verify_payload_files() {
    local app="$1" item relative
    # Fail closed on added source, logs, display journals, keys, symlinks, or
    # unexpected resources, including signed additions to an otherwise valid app.
    [[ ! -L "$app" ]] || { printf 'App bundle must not be a symlink.\n' >&2; exit 1; }
    while IFS= read -r -d '' item; do
        relative="${item#"$app"/}"
        [[ ! -L "$item" && ( -f "$item" || -d "$item" ) ]] || {
            printf 'Unsupported payload item: %s\n' "$relative" >&2; exit 1;
        }
        case "$relative" in
            Contents/CodeResources)
                # A stapled ticket is separate from _CodeSignature/CodeResources.
                # Only allow it in the mode which validates that ticket.
                [[ "$mode" == --notarized && -f "$item" ]] || {
                    printf 'Unexpected notarization ticket in community app.\n' >&2; exit 1;
                }
                ;;
            Contents|Contents/MacOS|Contents/Resources|Contents/_CodeSignature|\
            Contents/Info.plist|Contents/MacOS/Headroom|Contents/MacOS/DisplayGuardian|\
            Contents/_CodeSignature/CodeResources|Contents/Resources/AppIcon.icns|\
            Contents/Resources/StatusOff.pdf|Contents/Resources/StatusOn.pdf|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/Contents|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/Contents/Info.plist|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/Contents/Resources|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/Contents/Resources/black-hlg.mov|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/Contents/Resources/black-hlg-metadata.json|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/Contents/Resources/RESOURCE-ORIGIN.md|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/black-hlg.mov|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/black-hlg-metadata.json|\
            Contents/Resources/HeadroomPrototype_DisplayActivation.bundle/RESOURCE-ORIGIN.md) ;;
            *) printf 'Unexpected file in release app: %s\n' "$relative" >&2; exit 1 ;;
        esac
    done < <(find "$app" -mindepth 1 -print0)
}

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
elif [[ "$mode" == --community-signed ]]; then
    [[ -d "$source_app" && "$source_app" == *.app ]] || { printf 'Missing .app bundle: %s\n' "$source_app" >&2; exit 2; }
    channel="community-beta"
    verify_community_identity "$source_app"
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
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == local.gorka.Headroom && \
   "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$source_app/Contents/Info.plist")" == Headroom ]] || {
    printf 'Expected the Headroom application identifier and executable.\n' >&2; exit 1;
}
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid release version.\n' >&2; exit 1; }
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$source_app/Contents/Info.plist")"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid release build number.\n' >&2; exit 1; }
for executable in Headroom DisplayGuardian; do
    [[ "$(lipo -archs "$source_app/Contents/MacOS/$executable")" == arm64 ]] || { printf 'This release workflow expects arm64: %s\n' "$executable" >&2; exit 1; }
done
verify_payload_files "$source_app"
archive_name="Headroom-$version-$channel-arm64"
archive_path="$output_dir/$archive_name.zip"
checksum_path="$archive_path.sha256"
[[ ! -e "$archive_path" && ! -e "$checksum_path" ]] || { printf 'Release files already exist: %s\n' "$archive_path" >&2; exit 1; }
payload="$stage/$archive_name"
mkdir "$payload"
if [[ "$mode" == --notarized ]]; then
    ditto "$source_app" "$payload/Headroom.app"
else
    ditto --norsrc --noextattr "$source_app" "$payload/Headroom.app"
fi
cat > "$payload/READ-ME.txt" <<READ_ME
Headroom $version (build $build) — $channel
By Gorka Molero · https://github.com/Gorkamolero/Headroom

REQUIREMENTS
Apple silicon Mac and macOS 13 or later. Extra brightness requires a compatible
display with HDR/EDR headroom. Dimming requires writable display color tables.
Actual compatibility varies by Mac, display, macOS version, and settings.

INSTALL
1. Unzip the download and drag Headroom.app into Applications.
2. Open Headroom from Applications.
3. Allow Headroom in System Settings > Privacy & Security > Accessibility when
   macOS asks. Brightness keys work automatically while Headroom is running.
   Menu controls also work without this permission.
4. Quit Lunar before using Headroom's brightness keys. Headroom pauses its key
   handling while Lunar is running to avoid conflicting display controls.
5. Use the brightness keys, or click the black sun for each display's slider.
   Extra dimming and boost start OFF. The menu indicates unavailable controls.
6. Open at Login is enabled automatically on first launch after installation.
   Turn it off in the black-sun menu if unwanted; later launches respect that
   choice. If approval is pending, select Allow in Login Items to open System
   Settings and allow Headroom there. No daemon or separate startup helper is added.

BRIGHTNESS CONTROLS
Hold Brighter through normal hardware brightness and into extra brightness at
maximum. Hold Dimmer through normal brightness to the 1% hardware setting, then
into extra software dimming. The key keeps working across each boundary after a
short pause; release and press again to continue sooner. Option + Shift gives
smaller steps. Brightness keys target the built-in display, or the main display
when no built-in display is connected. The menu controls displays independently.

The fading overlay says Display, Display +, or Display - for the active range.
Switching a display off or quitting restores its saved original color tables.
Hardware brightness selected with the keys stays at its last setting. Sleep,
wake and display changes stop software adjustment; enable it again when wanted.

HOW IT WORKS
A tiny, paused HDR carrier requests EDR headroom. A separate recovery helper
scales the display's RGB transfer tables from a saved baseline. This changes
ordinary desktop appearance without screen recording or continuous video playback.

PRIVACY
No account, analytics, screen capture, or app network connection. The app stores
preferences and temporary recovery data locally. Brightness-key handling checks
event codes; other keys pass through and typed characters are not read or recorded.
macOS may require authentication for first opening and Accessibility permission.

SAFETY AND LIMITS
This is experimental software. Transfer-table values above 1 are outside Apple's
documented range and may behave differently across systems. Tests on the developer's
Mac verified restoration, including several crash cases; they cannot guarantee
compatibility or that nothing can go wrong. Extra brightness can use more power.
The slider is a table scaling factor, not a measured brightness multiplier.
If something looks wrong, turn boost off or quit; reopen Headroom for recovery.

ESTIMATED NITS
Normal brightness uses macOS's native nits report, with a linear-brightness/preset
fallback. Extra dimming assumes an sRGB response to the confirmed adjustment.
Display + shows a calculated, uncalibrated estimate marked "est.": it assumes an
extended-sRGB response to the confirmed adjustment, capped by current HDR capacity.
Display-table readback clamps values above 1 and does not validate this assumption.
The numbers are not physical measurements; 1600 nits is not guaranteed output.
Missing or unsettled readings show a dash. A meter is needed for calibration.

Source, method, test scope, and issue reporting:
https://github.com/Gorkamolero/Headroom
READ_ME
if [[ "$mode" == --beta || "$mode" == --community-signed ]]; then
    if [[ "$mode" == --community-signed ]]; then
        cat >> "$payload/READ-ME.txt" <<'COMMUNITY'

SIGNING STATUS
This community beta preserves the maintainer's persistent, self-signed code-signing
identity. It is not Developer ID signed or notarized, and its certificate does not
establish Apple trust. You do not need to install or trust a certificate manually.
The maintainer keeps the private signing key; only its public certificate is part
of the app signature. Future releases using this exact identity are intended to
retain Accessibility permission. Switching from an older ad-hoc build requires
one normal macOS approval; macOS policy or identity changes may require another.
COMMUNITY
    else
        cat >> "$payload/READ-ME.txt" <<'BETA'

SIGNING STATUS
This community beta has an ad-hoc signature. It is not Developer ID signed or
notarized by Apple. You can use the packaged app without compiling it or having
an Apple Developer membership.
BETA
    fi
    cat >> "$payload/READ-ME.txt" <<'BETA'

IF MACOS BLOCKS THE FIRST OPEN
If the message says the developer cannot be verified or Apple could not check
the app:
1. Dismiss the message and open System Settings > Privacy & Security.
2. Under Security, click Open Anyway next to the message about Headroom.
3. Authenticate if asked, then confirm Open.

macOS remembers this exception for Headroom. If Open Anyway is missing, try
opening Headroom from Applications again, then return to Privacy & Security.
Apple's instructions: https://support.apple.com/102445
BETA
else
    cat >> "$payload/READ-ME.txt" <<'SIGNED'

SIGNING STATUS
Developer ID signed, accepted by Apple's notarization service, and ticket stapled.
Notarization checks distribution security; it does not certify display compatibility.
SIGNED
fi
# Package and extract again to verify exactly what recipients receive.
if [[ "$mode" == --notarized ]]; then
    ditto -c -k --keepParent "$payload" "$stage/$archive_name.zip"
else
    ditto --norsrc --noextattr -c -k --keepParent "$payload" "$stage/$archive_name.zip"
fi
mkdir "$stage/verify"
ditto -x -k "$stage/$archive_name.zip" "$stage/verify"
verified_app="$stage/verify/$archive_name/Headroom.app"
codesign --verify --deep --strict "$verified_app"
verify_payload_files "$verified_app"
diff -qr "$source_app" "$verified_app" >/dev/null || { printf 'Packaged app differs from the supplied app.\n' >&2; exit 1; }
if [[ "$mode" == --community-signed ]]; then
    verify_community_identity "$verified_app"
fi
if [[ "$mode" == --notarized ]]; then
    xcrun stapler validate "$verified_app"
    spctl --assess --type execute --verbose=2 "$verified_app"
fi
mv "$stage/$archive_name.zip" "$archive_path"
(cd "$output_dir" && shasum -a 256 "$archive_name.zip" > "$archive_name.zip.sha256")
printf 'Packaged: %s\nChecksum: %s\n' "$archive_path" "$checksum_path"
