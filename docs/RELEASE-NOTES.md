# Headroom 0.5.0 — local candidate, build 18

- Added **≈ nits** for **Display +** in the overlay and per-display menu. An uncalibrated model interpolates from live native nits toward the lower of current EDR capacity and the active preset's HDR limit, according to the recovery helper's confirmed adjustment. It stays continuous at the normal/boost boundary and lowers its ceiling when current headroom drops. The tooltip identifies the model; this is not an optical measurement or a claim of sustained full-screen brightness.
- The read-only compatibility adapter now reads SDR and HDR limits from the same active-preset dictionary alongside linear brightness. Missing or invalid HDR metadata leaves native and dimmed nits available but makes boost nits unavailable. The calculation uses no hardcoded display maximum or potential-headroom substitute. Preparation, restoration, pending recovery, and unsupported readings still show **— nits**.

Build 18 is a local candidate; installation and validation status are recorded separately in [VALIDATION.md](../VALIDATION.md). The public 0.4.0 download is unchanged. See the [model and its assumptions](METHOD.md#estimated-nits--local-build-18).

# Headroom 0.5.0 — local candidate, build 17

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

# Headroom 0.4.0 — community beta

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

## Install the app

1. Download **Headroom-0.4.0-community-beta-arm64.zip** from the assets below and unzip it.
2. Drag **Headroom.app** into **Applications** and open it.
3. If macOS says the developer cannot be verified or Apple could not check the app, dismiss the message and open **System Settings → Privacy & Security**.
4. Under **Security**, click **Open Anyway** for Headroom, authenticate if asked, and confirm **Open**.
5. Click the black sun in the menu bar to turn on brightness boost.

If **Open Anyway** is missing, try opening Headroom from Applications again, then return to Privacy & Security. macOS remembers the exception for later launches. See [Apple's instructions](https://support.apple.com/102445).

The beta is ad-hoc signed, not Developer ID signed or notarized. No compiling or Apple Developer membership is needed to use the packaged app. Source code and checksums are also included. Headroom has recovery safeguards, but this beta does not promise identical behavior on every display or immunity from every OS failure.
