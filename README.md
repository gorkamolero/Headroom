<p align="center"><img src="Assets/AppIcon.png" width="128" alt="Headroom black sun icon"></p>

# Headroom

A small macOS menu bar app for extra dimming and brighter everyday desktop content on compatible displays.

**0.5.1 · Community beta**

Use your brightness keys across the normal display range, into extra dimming below it, and into HDR/EDR boost above it. Headroom keeps independent controls for each display in a compact black-sun menu. There is no main window, account, screen recording, or continuous video playback.

## Install

1. Open [Releases](https://github.com/gorkamolero/Headroom/releases) and download **Headroom-0.5.1-community-beta-arm64.zip**.
2. Quit an older Headroom copy and other brightness-control utilities, including Lunar, before replacing or opening Headroom.
3. Double-click the ZIP, drag **Headroom.app** into **Applications**, then open it there.

If macOS says the developer cannot be verified or Apple could not check the app:

1. Dismiss the message, then open **System Settings → Privacy & Security**.
2. Scroll to **Security** and click **Open Anyway** next to the message about Headroom.
3. Authenticate if asked, then click **Open** in the confirmation dialog.

This saves an exception for Headroom. If **Open Anyway** is missing, try opening Headroom from Applications once more, then return to Privacy & Security; managed Macs may restrict this option. This is [Apple's per-app opening procedure](https://support.apple.com/102445). These steps apply to an unidentified-developer or unnotarized-app alert, not a damaged-app or malware alert.

The 0.5.1 community build uses a persistent self-signed certificate. It is **not Developer ID signed or notarized**. **No compiling or Apple Developer membership is needed to use the downloaded app.**

### Allow brightness keys

On first use, allow **Headroom** in **System Settings → Privacy & Security → Accessibility**. Brightness-key handling starts automatically while the app is running; the menu controls work without this permission. Headroom's menu indicates when access is missing.

Upgrading from an older ad-hoc signed build can require approving Headroom once again because 0.5.0 introduces a persistent signing identity. If the old entry remains enabled but Headroom still reports missing access, remove that old Headroom entry and add **/Applications/Headroom.app**, then enable it. Subsequent releases signed with the same certificate are intended to preserve the permission; macOS remains in control of approval. No certificate installation or system-wide security change is needed.

## Using Headroom

- **Brighter:** hold the brightness-up key through the normal range and into boost at maximum.
- **Dimmer:** hold brightness-down through the normal range to the 1% hardware setting, then into extra software dimming.
- **Returning to normal:** hold in the opposite direction. Headroom restores the saved color tables at the boundary, then continues adjusting normal brightness without a second press.
- **Smaller steps:** hold **Option + Shift** with a brightness key.
- **Per-display controls:** click the black sun, enable a display, and move its slider. Switch it off to restore that display's original color tables.
- **Open at Login:** Headroom enables this automatically on its first launch after installation. Click the black sun and clear **Open at Login** to turn it off. Later launches respect your choice, including changes made in System Settings. If macOS needs approval, the menu shows a mixed state and **Allow in Login Items…**; select that row to open the relevant System Settings page.

The indicator reads **Display −**, **Display**, or **Display +** for extra dimming, normal brightness, and boost. Its evenly spaced ticks mark the ranges. A held key pauses briefly at a boundary before continuing, making the transition easier to judge. Releasing and pressing again, or reversing direction, skips that pause.

On launch, display adjustment is off. Headroom remembers each display's slider position. Sleep, locking, and display configuration changes stop current adjustments; use the keys or menu when you want to start again. If extra brightness is unavailable, the menu says so. If the backlight is already at zero, brightness-up raises it and brightness-down leaves it off.

Keys target the built-in display when connected, otherwise the primary display. Independent menu controls remain available for other displays. Keyboard handling pauses while Lunar is running; Headroom does not quit other apps for you. Where native brightness control is unavailable, ordinary keys fall back to macOS.

Switching off or choosing **Quit Headroom** restores the original color tables. The normal hardware brightness you selected with the keys stays at its last setting, just as it does with ordinary brightness controls.

### The nits readout

The menu and brightness indicator show **estimated nits**. Normal brightness uses macOS reporting with a preset-based fallback; extra dimming and boost apply an assumed light-response model to the confirmed display adjustment. **Display +** explicitly shows **≈… nits est.** Missing or unsettled readings show **— nits**.

These estimates are uncalibrated: no light meter has verified them, and a displayed value such as 1600 nits is not a measurement or a promise of sustained desktop brightness. The slider's 0.1–2.0 table range is also not a physical brightness ratio. See the [calculation and assumptions](docs/METHOD.md#estimated-nits-and-hdr-capacity--local-build-20).

## Compatibility

Headroom targets **Apple Silicon and macOS 13 or later**. Live testing has covered an M5 Pro MacBook Pro's built-in Liquid Retina XDR display on macOS 27.0.1. Other Mac, display, and OS combinations need confirmation. Extra brightness requires a compatible HDR/EDR display with headroom currently available. The indicator uses Apple's glass on macOS 26 or later and a vibrancy panel on older versions.

## Designed to restore your display

Headroom saves the original red, green, and blue display tables before changing them. Every adjustment starts from those originals, so adjustments cannot accumulate. A separate helper watches the app, and a saved recovery record supports restoration after an interrupted session.

Recorded tests restored the original tables with an **exact numerical readback match**, including normal disable, lost communication, termination, and crash-recovery scenarios. The [validation record](VALIDATION.md) distinguishes build-specific tests from the compatibility checks still outstanding.

This beta uses transfer-table values above Apple's documented range when boosting; behavior and color can vary between systems. Recovery safeguards reduce the impact of failures but cannot guarantee every hardware or OS condition. If a session is interrupted, reopen Headroom with the affected display connected so it can process its saved recovery record. See [recovery and troubleshooting](docs/RECOVERY.md).

## How it works

Extra dimming scales the saved display tables downward. Boost adds a tiny, paused HDR surface to make EDR headroom available, then scales those tables upward. The silent HDR sample is generated by this project; Headroom does not capture or redraw other apps.

Native-brightness control and nits reporting use small, isolated compatibility adapters for private macOS interfaces. If those interfaces are unavailable, the affected control or reading falls back or reports unavailability. The [method](docs/METHOD.md) explains the implementation and limits, with [Apple documentation](APPLE-SOURCES.md) alongside it.

## Privacy and permissions

Headroom runs locally, without telemetry, accounts, an app network client, or an automatic updater. It does not request Screen Recording, camera, microphone, or Full Disk Access permissions. On first launch after installation, Headroom registers itself with macOS Login Items. This opens the app itself; it installs no daemon, LaunchAgent, or separate startup helper. You can turn **Open at Login** off in the menu, which reflects macOS's current setting. A local marker records that first-launch setup has run, so subsequent launches respect your choice.

Accessibility permission enables brightness-key handling. Headroom checks event codes to recognize brightness buttons; other keys pass through unchanged, and typed characters are never read or recorded.

The app stores per-display slider preferences and local recovery data. Recovery records contain display identifiers and original color tables; they are retained when recovery needs another attempt. See [local data and removal](docs/RECOVERY.md#local-data-and-removal).

## Build from source

Building is optional. To use the packaged app, follow [Install](#install). Developers need **Xcode 26 or later with the macOS 26 SDK**. The app still targets macOS 13 or later; the newer SDK is required to compile its glass interface support:

```sh
swift test
./scripts/build-menu-app.sh --beta "$PWD/dist/Headroom.app"
open "$PWD/dist/Headroom.app"
```

That command creates a separate ad-hoc development build; it does not reproduce the maintainer's persistent signing identity. [Release packaging](docs/RELEASING.md) explains the signed community artifact and optional source archive.

The repository also contains `HeadroomLab`, the earlier bounded Metal experiment, for development. It is not part of the normal menu-bar experience.

## Feedback

Useful reports include your Mac model, macOS version, display model and connection, whether keys move correctly between ranges, and whether switching off restores normal appearance. Include the menu's error text when relevant. Avoid posting full recovery journals because they contain display identifiers.

See [release notes](docs/RELEASE-NOTES.md), [validation](VALIDATION.md), and [the technical method](docs/METHOD.md). Headroom is an independent project by Gorka Molero.
