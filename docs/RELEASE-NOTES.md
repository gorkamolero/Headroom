# Headroom 0.5.1 — community beta

Build 23 enables **Open at Login** automatically on the first launch after installation. The black-sun menu includes a checkbox to turn it off.

- Uses macOS Login Items to open Headroom itself, with no daemon, LaunchAgent, or separate startup helper.
- The checkbox reflects the current macOS setting. One-time setup does not re-enable it on later launches after you turn it off in the menu or System Settings.
- If approval is pending, the checkbox shows a mixed state and **Allow in Login Items…** opens the relevant settings. Turning the checkbox off cancels the request.

Download **Headroom-0.5.1-community-beta-arm64.zip**, quit the existing app, and replace **Headroom.app** in **Applications**. Follow the [installation instructions](../README.md#install) if macOS blocks the first opening. This release retains the persistent self-signed identity; it is not Developer ID signed or notarized. Brightness-key access still uses the normal Accessibility permission.

Display adjustment remains off on launch. The brightness controls, restoration behavior, and uncalibrated nits estimates from 0.5.0 are unchanged. [Validation](../VALIDATION.md) records completed checks separately from release preparation.

# Headroom 0.5.0 — community beta

Brightness keys now move continuously through extra dimming, normal brightness, and HDR/EDR boost. Hold a key to cross ranges without releasing and pressing again; the indicator briefly pauses at each boundary and labels the current range **Display −**, **Display**, or **Display +**.

- Automatic brightness-key handling while Headroom runs, with Option–Shift for smaller steps.
- Extra dimming below the 1% hardware slider setting and boost above the normal maximum on supported displays.
- Original color-table restoration before a held key returns to normal hardware adjustment.
- A compact native-style indicator with evenly spaced ticks and two visible range boundaries.
- Estimated nits in the indicator and per-display menu. Boost is explicitly labelled **≈… nits est.**; missing or unsettled readings show **— nits**.
- Independent menu switches and sliders, with saved settings per display.
- A persistent certificate-bound signing identity for the app and recovery helper, preserved in the release archive.

The nits display is an uncalibrated estimate based on macOS reporting and an assumed response to software adjustment. It is not a light-meter measurement, and a displayed value does not promise sustained full-screen brightness. The [method](METHOD.md#estimated-nits-and-hdr-capacity--local-build-20) explains the calculation; [validation](../VALIDATION.md) records build-specific tests and remaining compatibility work.

## Install or update

1. Download **Headroom-0.5.0-community-beta-arm64.zip** and unzip it.
2. Quit an older Headroom copy and other brightness utilities, including Lunar. Move the new **Headroom.app** into **Applications**, replacing the old app, then open it.
3. If macOS says the developer cannot be verified or Apple could not check the app, open **System Settings → Privacy & Security → Security → Open Anyway** for Headroom, authenticate if asked, and confirm **Open**.
4. Allow Headroom in **System Settings → Privacy & Security → Accessibility** for brightness keys. The menu controls also work without that permission.
5. Use your brightness keys, or click the black sun for per-display controls.

An upgrade from an ad-hoc signed build may need one fresh Accessibility approval. If the older entry appears enabled but Headroom still reports missing access, remove the old Headroom entry and add **/Applications/Headroom.app**, then enable it. Future releases must retain this certificate identity to preserve permission continuity; macOS policy still applies. The locally verified build 20-to-21 update retained brightness-key access with different code hashes and the same certificate-bound requirement.

This community release is self-signed with a persistent certificate, **not Developer ID signed or notarized**. No compiling, certificate installation, or Apple Developer membership is needed to use it. Source and checksums are separate release assets. macOS remembers the per-app opening exception; managed Macs may restrict it. See [Apple's opening instructions](https://support.apple.com/102445). Do not apply these exception steps to a damaged-app or malware alert.

The app targets Apple Silicon and macOS 13 or later. Live testing has covered an M5 Pro internal XDR display on macOS 27.0.1. Native-brightness and nits adapters depend on private macOS interfaces and report unavailable data or fall back when those interfaces cannot be used. Quit restores original color tables; hardware brightness selected with the keys stays at its last setting.

## Development history

The following entries preserve the earlier candidate results and decisions. References to the public 0.4.0 download describe the state at the time of each entry.

<details>
<summary>0.5.0 candidate builds</summary>

### Build 21 — persistent signing

- Local updates can reuse one certificate-bound signing identity instead of resetting identity with every ad-hoc rebuild. The certificate's private key stays in Keychain; local configuration contains only its public fingerprint and refuses an ad-hoc fallback.
- After the one-time permission transition, installing build 21 over signed build 20 retained the running app's brightness-key access without another prompt. Both apps have different code hashes and the same certificate-bound requirement.
- Includes build 20's explicitly estimated nits readout. No brightness-control or HUD geometry changes.

Build 21 is installed locally. This signing mode is not Developer ID signing or notarization; the public 0.4.0 release remains unchanged. See [local signing](RELEASING.md#persistent-signing-for-local-updates) and [validation](../VALIDATION.md).

### Build 20 — estimated boost nits

- **Display +** now shows a calculated **≈… nits est.** readout in the overlay and per-display menu. It uses the live native nits reference and the table factor acknowledged by the recovery helper, with an explicitly assumed extended-sRGB response capped at live HDR capacity.
- The estimate assumes the encoded adjustment survives into EDR without clipping before decoding. Normalized table readback clamps values above 1 on the test Mac, so this remains an uncalibrated prediction, not a measured optical response. Tooltip and accessibility text state that limitation; the HDR ceiling remains separate from the predicted value.
- The calculation joins native brightness at factor 1 and uses no mapping from the slider endpoint to 1600 nits. Missing readings or inconsistent capacity show **— nits**. Native and dimmed readings retain their existing calculations.

Build 20 supersedes build 19's capacity-only readout. Build-specific verification and installation status are recorded separately in [VALIDATION.md](../VALIDATION.md). The public 0.4.0 download is unchanged. See the [calculation and assumptions](METHOD.md#estimated-nits-and-hdr-capacity--local-build-20).

### Build 19 — superseded capacity-only readout

- Replaced build 18's unsupported boost-nits interpolation. **Display +** now shows a separately labelled **HDR ceiling**, such as **HDR ≤480 nits**; it never presents that capacity as attained desktop brightness.
- Native SDR white now comes directly from macOS CoreBrightness telemetry, with the existing linear-brightness/preset calculation as a fallback. Extra dimming retains its explicitly assumed sRGB estimate.
- Background, freshness-limited reads keep private system calls off the key-handling thread. Invalid display identities, missing readings, and stale results fail closed.

Superseded by build 20. Installation and evidence are recorded in [VALIDATION.md](../VALIDATION.md). The public 0.4.0 download is unchanged. See the [current calculation and limits](METHOD.md#estimated-nits-and-hdr-capacity--local-build-20).

### Build 18 — superseded interpolation

- Added **≈ nits** for **Display +** in the overlay and per-display menu. An uncalibrated model interpolates from live native nits toward the lower of current EDR capacity and the active preset's HDR limit, according to the recovery helper's confirmed adjustment. It stays continuous at the normal/boost boundary and lowers its ceiling when current headroom drops. The tooltip identifies the model; this is not an optical measurement or a claim of sustained full-screen brightness.
- The read-only compatibility adapter now reads SDR and HDR limits from the same active-preset dictionary alongside linear brightness. Missing or invalid HDR metadata leaves native and dimmed nits available but makes boost nits unavailable. The calculation uses no hardcoded display maximum or potential-headroom substitute. Preparation, restoration, pending recovery, and unsupported readings still show **— nits**.

Build 18 was superseded by build 19; installation and validation status are recorded separately in [VALIDATION.md](../VALIDATION.md). The public 0.4.0 download is unchanged. See the [current method](METHOD.md#estimated-nits-and-hdr-capacity--local-build-20).

### Build 17 — brightness keys and dimming

- Added a live **≈ nits** estimate at the upper right of the brightness overlay and in each display's menu controls. It uses the Mac's linear brightness reading and that display's active SDR preset maximum. Extra dimming includes an explicitly assumed sRGB response to confirmed table changes. Unsupported readings, boost, preparation, restoration, and pending recovery display **— nits**. These are calculated estimates, not physical light-meter measurements.

- Kept all 17 ticks on one evenly spaced grid. Only ticks 2 and 14 are taller; the visual range boundaries align with those same ticks.
- Removed duplicate boundary marks: the bar now has a single set of ticks, with the existing boundary graduations slightly taller. The public 0.4.0 release is unchanged.

- The indicator now says **Display −**, **Display**, or **Display +** for extra dimming, normal brightness, and boost. Small vertical notches mark the two boundaries. Held keys pause for 350 ms at a confirmed boundary, then continue; release/repress or reversing direction skips the pause.

- Removed the fixed 1.5-second boost startup delay. Activation now proceeds as soon as the HDR frame and current display headroom are ready. Timed Up-repeat tests check actual display-table changes before release, including a 750 ms hold. Normal brightness and Down handling are unchanged.

- Automatic brightness-key handling while Headroom runs. Accessibility permission is requested once on first use; later launches report missing access in the menu without repeating the prompt. Headroom owns supported keys across normal hardware brightness, boost, and extra dimming. No release or second press is needed at either boundary.
- Holding Down lowers hardware brightness to a 1% slider setting, then enters extra software dimming without lowering the backlight further. If hardware brightness is already zero, Up raises it and Down leaves it off. The hardware percentage is not a physical luminance measurement.
- Holding Down reduces boost; holding Up reduces extra dimming. Reaching the unchanged baseline restores the saved tables before the held key resumes normal hardware changes. Hold Option–Shift for fine adjustments.
- Per-display sliders cover table factors from 0.1 to the available boost ceiling, at most 2.0. Extra dimming uses the saved original tables without an HDR carrier; these factors are not measured luminance ratios.
- One native-style overlay across all supported ranges, built with Apple's glass and slider controls on macOS 26 or later, with a compatible vibrancy panel on older systems. White bar, tick marks, and sun icons; automatic fade and no percentage or multiplier label.
- Accessibility is requested only for key control. Keys target the built-in display, or the primary display on a desktop Mac, and pause while Lunar is running.
- Handles both system-defined brightness events and alternate brightness keycodes 144/145, including held keys and releases. Ordinary keys pass through unchanged.
- Two isolated private adapters provide native-brightness control and read-only nits reporting. Native writes validate levels and check readback. The nits adapter uses DisplayServices and runtime-checked MonitorPanel getters with a nonblocking lock; unavailable APIs return no estimate. Neither adapter changes automatic brightness. If native control is unavailable, ordinary keys fall back to macOS. The overlay uses public controls because the tested system-banner interfaces are unavailable to Headroom.
- Disable and quit restore the original color tables. Hardware brightness selected with the keys remains at its last setting.

Build-specific test, installation, and visual results are recorded in [VALIDATION.md](../VALIDATION.md). Physical-key repetition and the restoration handoff remain separate live checks. This candidate has not replaced the public 0.4.0 download.

Updating an ad-hoc signed beta may require enabling Headroom in Accessibility again because the build's identity changes. Headroom preserves macOS's normal permission checks.

</details>

## Headroom 0.4.0 — earlier community beta

Headroom adds a small black-sun menu to macOS with independent brightness controls for compatible XDR displays. It uses the display's available EDR headroom for brighter ordinary desktop content, with a saved slider setting for each display.

- Compact native menu with an on/off switch and slider per display.
- Black-sun artwork adapted from Gorka Molero's Saga project.
- A silent, paused HDR sample; no screen recording or continuous playback.
- Original display tables saved before adjustment, with every change calculated from that baseline.
- A separate recovery helper, session heartbeat, and saved recovery records.
- Restoration on disable and quit, plus lifecycle handling for sleep and display changes.
- Local operation without telemetry, accounts, or a permanent background service.

The recorded menu scale tests returned every original RGB table sample exactly after disabling. Earlier lab fault tests also verified numerical restoration. The [validation record](../VALIDATION.md) gives the scope of those results and the remaining compatibility work.

This is an early community beta for Apple Silicon. The build targets macOS 13 or later; live testing has covered an M5 Pro internal XDR display on macOS 27.0.1. Brightness in nits, color accuracy, sustained GPU use, and battery impact have not been measured. The maximum slider setting is a requested table scale, not a measured 2× brightness gain.

### Install the 0.4.0 app

1. Download **Headroom-0.4.0-community-beta-arm64.zip** from the assets below and unzip it.
2. Drag **Headroom.app** into **Applications** and open it.
3. If macOS says the developer cannot be verified or Apple could not check the app, dismiss the message and open **System Settings → Privacy & Security**.
4. Under **Security**, click **Open Anyway** for Headroom, authenticate if asked, and confirm **Open**.
5. Click the black sun in the menu bar to turn on brightness boost.

If **Open Anyway** is missing, try opening Headroom from Applications again, then return to Privacy & Security. macOS remembers the exception for later launches. See [Apple's instructions](https://support.apple.com/102445).

The beta is ad-hoc signed, not Developer ID signed or notarized. No compiling or Apple Developer membership is needed to use the packaged app. Source code and checksums are also included. Headroom has recovery safeguards, but this beta does not promise identical behavior on every display or immunity from every OS failure.
