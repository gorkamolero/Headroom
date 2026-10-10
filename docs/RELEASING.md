# Building and releasing Headroom

Headroom 0.4.0 is a community beta for Apple Silicon. The build targets macOS 13 or later; the [validation record](../VALIDATION.md) describes the systems actually tested. Packaging keeps local evidence, source files, and recovery records out of the download.

## Beta and source release

Run tests, then create an ad-hoc signed app and ZIP:

```sh
swift test
./scripts/package-release.sh --beta dist
```

The output is `Headroom-0.4.0-community-beta-arm64.zip` with a matching `.zip.sha256` checksum. The ZIP contains `Headroom.app` and `READ-ME.txt`. An ad-hoc signature checks bundle integrity locally; it does not establish a Developer ID identity or provide notarization. macOS may block a downloaded beta from opening. Building from source is the recommended route for this release.

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
