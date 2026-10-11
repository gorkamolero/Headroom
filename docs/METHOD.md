# How Headroom works

Headroom combines an HDR activation surface with a display transfer-table adjustment. Enabling EDR by itself does not document or guarantee an increase in the brightness of other applications.

## 1. Check the display

The app reads each `NSScreen`'s potential and current EDR headroom. It requires a connected, non-mirrored display with potential headroom greater than 1.01. Current headroom is checked again after activation and while running. If the system provides no extra range, the session stops and the menu reports unavailability.

Physical display identity, display mode, and color-profile configuration are recorded. The boost and recovery implementation uses public AppKit, Core Graphics, AVFoundation, and QuartzCore APIs. The separate development lab also uses Metal. The local 0.5.0 candidate adds two private integrations for optional keyboard control: a normal-brightness getter and a request to Apple's system Display overlay. Each is isolated in a compatibility adapter.

## 2. Make an HDR surface available

For an enabled display, `HDRCarrier` creates a transparent 5 × 5 point nonactivating panel with a 1 × 1 point `AVPlayerLayer`. It loads this project's own 64 × 64 pixel black HLG sample, encoded as 10-bit HEVC. The player is muted and remains at rate zero: there is no play, seek, loop, screen capture, or continuous rendering routine.

Preparation waits for both the asset and a displayable first frame, then gives macOS 1.5 seconds to settle. An eight-second preparation timeout prevents an indefinite wait. Current EDR headroom is checked before starting any table change. The sample's [generation command and provenance](../Sources/DisplayActivation/Resources/RESOURCE-ORIGIN.md) are included in the source.

The earlier lab renders a single EDR-enabled Metal frame instead. The paused carrier is the menu app's present implementation; those paths must be validated separately.

## 3. Scale from an immutable baseline

A separate `DisplayGuardian` process acquires a lock for the physical display, checks pending recovery records, reads the original RGB tables and their actual sample count, and durably saves them before the first write.

For a requested multiplier `m`, each channel's proposed sample is:

```text
proposed[i] = original[i] × m
```

Every adjustment uses `original`, never the preceding result. The effective multiplier is limited by the requested slider position, 2.0, potential headroom, and current headroom. Default selections vary by display type; the app remembers a changed selection per display.

Apple documents transfer-table samples between 0 and 1. Proposed samples above 1 use behavior outside that documented range. On the test machine, readback was capped at 1 even when larger values were submitted. The visible result depends on the display pipeline; the API result cannot establish physical brightness or final highlight clipping. A factor of 2.0 therefore must not be advertised as doubling brightness. See [Apple sources](../APPLE-SOURCES.md) and [validation](../VALIDATION.md).

## 4. Keep recovery independent

The menu app sends a heartbeat every second and renews a 30-second lease every ten seconds. The helper starts restoration after five seconds without a heartbeat, lease expiry, closed parent input, an explicit stop, or handled termination. The parent also watches helper replies; if the helper freezes, it runs a bounded termination and recovery sequence.

Normal disable and quit restore the original tables and read them back before retiring the recovery record. Recovery accepts a maximum sample difference of 0.0005; the recorded restoration runs achieved 0.0. A shared lock prevents another Headroom instance or the lab from capturing an already boosted table as a new baseline.

Recovery checks the physical display and its configuration. If the display is disconnected, its profile has changed, or another transform is active, Headroom retains its record and blocks a new session rather than blindly overwriting the current display state. Reopening the app retries pending recovery for connected displays.

Sleep, display sleep, lock, wake, and relevant display changes end or pause sessions. A new boost requires explicit enable. No privileged helper, login item, firmware change, or permanent background daemon is installed.

## Brightness keys — next beta

This feature is in development and is not included in the 0.4.0 release. **Use Brightness Keys** is opt-in and requires Accessibility permission. A Core Graphics event tap handles brightness media keys; other input passes through and is not recorded. Screen Recording is not required.

Below normal maximum, brightness keys pass through to macOS. At maximum, a fresh Up press starts the existing boost session; a held key does not cross that boundary. Down reduces boost, restores the original tables when leaving boost, and then returns control to macOS. Option + Shift selects smaller increments. Pending key actions are discarded on sleep or quit. The helper, saved baseline, lease, and restoration checks remain the same.

Media-key events contain no physical display UUID. Headroom targets the connected built-in display, or the primary display when no built-in display is connected. Independent menu controls remain available for every supported display. Keyboard handling pauses while Lunar runs, without quitting or changing Lunar. This feature does not add external-monitor DDC, below-normal software dimming, or automatic brightness control.

Headroom requests Apple's system Display overlay after boost-key adjustments. macOS supplies the rendering and fade; Headroom adds no percentage or multiplier label. The requested fill is `factor / maximumFactor`, clamped to 0–1, so reducing boost toward a factor of 1 does not jump the bar to full. This is a control position, not measured luminance or a claim of twice the brightness. When keys pass through, macOS handles the ordinary brightness indicator and its own scale. Status and errors stay in Headroom's menu. If the system indicator is unavailable, no custom panel is substituted.

`NormalBrightnessReader` dynamically loads `DisplayServicesGetBrightness` to read native brightness. This private API determines the normal-maximum boundary and detects system brightness changes during a keyboard-controlled session. It does not set brightness. Missing or unsuccessful readings prevent automatic entry into boost. `NativeBrightnessOSD` separately loads the private OSD framework and validates `OSDManager` method signatures before requesting the indicator. Neither adapter changes the display preset or automatic brightness. No Lunar code or assets are included. See [Apple sources](../APPLE-SOURCES.md#brightness-keys--next-beta).

Physical media-key repetition and restoration handoff remain separate live checks; [validation](../VALIDATION.md) records results by build. Updated ad-hoc builds may need Accessibility approval again because their code identity changes; Headroom keeps the normal macOS permission and signature checks.

## Scope of the safeguards

Saving the baseline before writing, using a separate helper, checking ownership, and keeping an interrupted session's record provide multiple opportunities to restore it. They cannot provide an absolute guarantee through simultaneous app/helper termination, an operating-system failure, or a disconnected display. In a simultaneous failure, restoration may wait until Headroom is reopened with that display available.

This design is intended for everyday brightness adjustment. Instrumented color accuracy, maximum physical luminance, battery impact, and broad hardware compatibility remain validation work; see the [matrix](../VALIDATION.md#remaining-compatibility-work).
