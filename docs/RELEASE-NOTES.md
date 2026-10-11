# Headroom 0.5.0 — local candidate, build 10

- Automatic brightness-key handling while Headroom runs. Accessibility permission is requested once on first use; later launches report missing access in the menu without repeating the prompt. Release and press Up at normal maximum to enter boost, or Down at the lowest lit step to enter extra dimming. A held native key requires release before entering either extra range.
- Extra dimming leaves hardware brightness unchanged. A held Down stops at the lowest lit step; if hardware brightness is already zero, Up remains with macOS to light it again.
- Down reduces boost; Up reduces extra dimming. Reaching the unchanged baseline restores the saved tables and returns control to macOS. Hold Option–Shift for fine adjustments.
- Per-display sliders cover table factors from 0.1 to the available boost ceiling, at most 2.0. Extra dimming uses the saved original tables without an HDR carrier; these factors are not measured luminance ratios.
- A native-style **Display +** overlay built with Apple's glass and slider controls on macOS 26 or later, with a compatible vibrancy panel on older systems. White bar, tick marks, and sun icons; automatic fade and no percentage or multiplier label.
- Accessibility is requested only for key control. Keys target the built-in display, or the primary display on a desktop Mac, and pause while Lunar is running.
- One isolated private adapter reads normal brightness. It does not change automatic brightness or use a private brightness setter. The overlay uses public controls because the tested system-banner interfaces are unavailable to Headroom.

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
