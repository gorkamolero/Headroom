# Building and releasing Headroom

Headroom 0.5.0 is a community beta for Apple Silicon. The build targets macOS 13 or later; [validation](../VALIDATION.md) describes the systems and builds actually tested. Users install the packaged app directly; building from source is optional. Source builds require **Xcode 26 or later with the macOS 26 SDK**, even though the deployment target remains macOS 13.

## Package the verified community build

The 0.5.0 release preserves the persistent certificate-bound identity of the verified app. It is self-signed, not Developer ID signed or notarized. Package the exact approved installation rather than rebuilding it with an ad-hoc signature:

```sh
./scripts/package-release.sh --community-signed \
  /Applications/Headroom.app dist/release-0.5.0
```

The output is **Headroom-0.5.0-community-beta-arm64.zip** and its matching **.zip.sha256** checksum in `dist/release-0.5.0`. The ZIP contains `Headroom.app` and `READ-ME.txt`, with no source, logs, recovery journals, or signing credentials. This mode verifies the supplied app's certificate-bound signing identity and packages it without changing that identity. It reads the expected public fingerprint from `HEADROOM_SIGNING_IDENTITY` or the saved configuration described below; packaging needs neither the private key nor an unlocked signing keychain.

Recipients follow the [installation instructions](../README.md#install), including macOS's per-app **Open Anyway** action when needed. Brightness keys require Accessibility permission. An upgrade from an earlier ad-hoc build can require one fresh approval; subsequent updates must retain the same certificate and designated requirement to preserve the app's identity.

For installation on another Mac, use the app extracted from this same release ZIP. Check its archive checksum and verify its bundle signature after extraction. That ensures the installed app matches the distributed release; a separately rebuilt copy is a different artifact. Packaging does not publish the release or install it remotely.

## Source archive

The optional **Headroom-0.5.0-source.zip** contains the committed source, icon assets, tests, and documentation. Create it only after the final release changes are committed and the checkout is clean:

```sh
git archive --format=zip --prefix=Headroom-0.5.0/ HEAD \
  > dist/release-0.5.0/Headroom-0.5.0-source.zip
(cd dist/release-0.5.0 && shasum -a 256 Headroom-0.5.0-source.zip \
  > Headroom-0.5.0-source.zip.sha256)
```

Use that same commit for the release tag. Raw display evidence, build caches, and signing keys stay outside the archive. Never share a keychain or certificate private key with recipients.

## Ad-hoc development builds

Developers without the maintainer's signing key can still build and test locally:

```sh
swift test
./scripts/build-menu-app.sh --beta "$PWD/dist/development/Headroom.app"
```

To package an explicitly ad-hoc development beta:

```sh
./scripts/package-release.sh --beta dist/development-package
```

These builds do not preserve the community release's identity and may require their own Accessibility approval. Keep them separate from the installed community app. Build and packaging scripts refuse to overwrite existing outputs; use a fresh directory for another candidate.

## Persistent signing for local updates

Ad-hoc signatures identify an individual build. Rebuilding changes that identity, so macOS can require Accessibility approval again. For a frequently updated local installation, create one code-signing certificate and private key in Keychain and reuse that identity for subsequent builds. A self-signed local certificate is sufficient for this workflow; it does not provide Developer ID signing or notarization.

Find the certificate's exact 40-character SHA-1 fingerprint with `security find-identity -p codesigning`. Save that fingerprint once for local updates, replacing the placeholder below with the actual value:

```sh
mkdir -p "$HOME/Library/Application Support/Headroom Development"
printf '%s\n' '<40-hex certificate fingerprint>' > \
  "$HOME/Library/Application Support/Headroom Development/signing-identity"
./scripts/build-menu-app.sh --local "$PWD/dist/local/Headroom.app"
```

The saved file contains only the fingerprint, with an optional final newline. It is read as data, never executed. An explicit `HEADROOM_SIGNING_IDENTITY` overrides this file and must itself be a valid 40-character fingerprint; an invalid or empty override fails instead of falling back. The local build and certificate-preserving community-package workflows use this identity. Ad-hoc beta and Developer ID builds keep their explicit signing workflows.

If the identity lives in a separate keychain, also set `HEADROOM_SIGNING_KEYCHAIN` to that existing keychain's absolute path. Keep the keychain unlocked for signing through macOS's normal controls. The build never creates identities, changes trust settings, or falls back to ad-hoc signing. It makes no timestamp request.

Local mode signs the app and guardian with the same certificate and distinct identifiers. Each designated requirement binds the identifier to that exact certificate. Verification rejects code-hash-only and identifier-only requirements; knowing the bundle identifier is not sufficient to impersonate the app. Do not regenerate the certificate for each build, change the app identifier, or replace the private key during routine updates. Keep all keys and keychain files outside the repository and release archives.

Moving from the existing ad-hoc installation to this persistent identity still requires one normal macOS approval. Later builds using the same certificate and designated requirement are intended to preserve that permission; verify the installed app's brightness-key access after updates. Changes to macOS policy or the signing identity may require a new approval. Do not edit the permission database or weaken signing requirements to avoid it.

Use `--community-signed` to package a verified build with this persistent identity without rebuilding or re-signing it. The certificate does not remove Gatekeeper checks for recipients and does not become a Developer ID certificate by being used for a community release.

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

This step uploads the signed candidate to Apple's notary service. The script requires an accepted result, staples the ticket, verifies it, and performs a Gatekeeper assessment before producing `Headroom-0.5.0-notarized-arm64.zip` and its `.zip.sha256` checksum. Submission needs the maintainer's Apple credentials; a successful ad-hoc build cannot substitute for them.

Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) explains the Developer ID, hardened runtime, and secure timestamp requirements. [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) covers command-line submission and stapling.

Before publishing, test the final downloaded artifact through normal Gatekeeper behavior, including launch, a supported display session, disable, and quit. Keep compatibility limitations in the release notes. Signing and notarization address distribution identity and Apple's malware/code-signing checks; they do not establish physical brightness, color accuracy, or immunity from display bugs.

## Release choice

The maintainer has chosen a community beta and optional source archive without an Apple Developer Program membership. The 0.5.0 binary uses a persistent self-signed certificate. Developer ID signing and notarization are not part of this release; their scripts remain available if that distribution choice changes later.

Keep the signing status and compatibility limits visible when sharing. Record publication only after the remote release and all assets have been verified, and install the exact packaged artifact on any destination Mac.
