# Building and releasing Headroom

Headroom 0.4.0 is a community beta for Apple Silicon. The build targets macOS 13 or later; the [validation record](../VALIDATION.md) describes the systems actually tested. Packaging keeps local evidence, source files, and recovery records out of the download.

## Beta and source release

Run tests, then create an ad-hoc signed app and ZIP:

```sh
swift test
./scripts/package-release.sh --beta dist
```

The output is `Headroom-0.4.0-community-beta-arm64.zip` with a matching `.zip.sha256` checksum. The ZIP contains `Headroom.app` and `READ-ME.txt`. An ad-hoc signature checks bundle integrity locally; it does not establish a Developer ID identity or provide notarization. Recipients can install the app directly using the [installation steps](../README.md#install), including macOS's **Open Anyway** action when required. Building from source is optional.

The accompanying `Headroom-0.4.0-source.zip` contains the committed source, icon assets, tests and documentation, with no build cache, raw display journals or signing credentials. Create it from a clean, committed checkout:

```sh
git archive --format=zip --prefix=Headroom-0.4.0/ HEAD > dist/Headroom-0.4.0-source.zip
(cd dist && shasum -a 256 Headroom-0.4.0-source.zip > Headroom-0.4.0-source.zip.sha256)
```

To build only the app:

```sh
./scripts/build-menu-app.sh --beta "$PWD/dist/Headroom.app"
```

Build scripts refuse to overwrite an existing app. Use a fresh output directory for another candidate, or deliberately move an earlier candidate after quitting it. Keep the running installation separate from release staging.

## Persistent signing for local updates

Ad-hoc signatures identify an individual build. Rebuilding changes that identity, so macOS can require Accessibility approval again. For a frequently updated local installation, create one code-signing certificate and private key in Keychain and reuse that identity for subsequent builds. A self-signed local certificate is sufficient for this workflow; it does not provide Developer ID signing or notarization.

Find the certificate's exact 40-character SHA-1 fingerprint with `security find-identity -p codesigning`. Save that fingerprint once for local updates, replacing the placeholder below with the actual value:

```sh
mkdir -p "$HOME/Library/Application Support/Headroom Development"
printf '%s\n' '<40-hex certificate fingerprint>' > \
  "$HOME/Library/Application Support/Headroom Development/signing-identity"
./scripts/build-menu-app.sh --local "$PWD/dist/local/Headroom.app"
```

The saved file contains only the fingerprint, with an optional final newline. It is read as data, never executed. An explicit `HEADROOM_SIGNING_IDENTITY` overrides this file and must itself be a valid 40-character fingerprint; an invalid or empty override fails instead of falling back. Only `--local` reads this configuration. Beta and Developer ID builds keep their explicit signing workflows.

If the identity lives in a separate keychain, also set `HEADROOM_SIGNING_KEYCHAIN` to that existing keychain's absolute path. Keep the keychain unlocked for signing through macOS's normal controls. The build never creates identities, changes trust settings, or falls back to ad-hoc signing. It makes no timestamp request.

Local mode signs the app and guardian with the same certificate and distinct identifiers. Each designated requirement binds the identifier to that exact certificate. Verification rejects code-hash-only and identifier-only requirements; knowing the bundle identifier is not sufficient to impersonate the app. Do not regenerate the certificate for each build, change the app identifier, or replace the private key during routine updates. Keep all keys and keychain files outside the repository and release archives.

Moving from the existing ad-hoc installation to this persistent identity still requires one normal macOS approval. Later builds using the same certificate and designated requirement are intended to preserve that permission; verify the installed app's brightness-key access after updates. Changes to macOS policy or the signing identity may require a new approval. Do not edit the permission database or weaken signing requirements to avoid it.

This mode is for local installations. Continue using the explicitly labelled beta or Developer ID workflows for public release packaging. A local certificate does not remove Gatekeeper checks for recipients.

## Optional future Developer ID candidate

A configured **Developer ID Application** signing identity is required. With that identity already available in the signing keychain:

```sh
HEADROOM_SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' \
  ./scripts/package-release.sh --developer-id dist
```

Replace the example identity with the actual configured identity. This creates a signed candidate at `dist/Headroom.app`; it does not publish anything. Do not add certificates, private keys, passwords, or notarization credentials to the repository.

## Optional future notarization

After configuring an Apple notarization keychain profile, pass its name:

```sh
./scripts/notarize-release.sh "$PWD/dist/Headroom.app" KEYCHAIN_PROFILE dist
```

This step uploads the signed candidate to Apple's notary service. The script requires an accepted result, staples the ticket, verifies it, and performs a Gatekeeper assessment before producing `Headroom-0.4.0-notarized-arm64.zip` and its `.zip.sha256` checksum. Submission needs the maintainer's Apple credentials; a successful ad-hoc build cannot substitute for them.

Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) explains the Developer ID, hardened runtime, and secure timestamp requirements. [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) covers command-line submission and stapling.

Before publishing, test the final downloaded artifact through normal Gatekeeper behavior, including launch, a supported display session, disable, and quit. Keep compatibility limitations in the release notes. Signing and notarization address distribution identity and Apple's malware/code-signing checks; they do not establish physical brightness, color accuracy, or immunity from display bugs.

## Release status

The maintainer has chosen a beta/source release without an Apple Developer Program membership. Developer ID signing and notarization are not part of 0.4.0. The optional scripts remain available if that distribution choice changes later. Keep the beta's signing status and compatibility limits visible when sharing it.
