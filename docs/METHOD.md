# How Headroom works

Headroom combines an HDR activation surface with a display transfer-table adjustment. Enabling EDR by itself does not document or guarantee an increase in the brightness of other applications.

## 1. Check the display

The app reads each `NSScreen`'s potential and current EDR headroom. It requires a connected, non-mirrored display with potential headroom greater than 1.01. Current headroom is checked again after activation and while running. If the system provides no extra range, the session stops and the menu reports unavailability.

Physical display identity, display mode, and color-profile configuration are recorded. The implementation uses public AppKit, Core Graphics, AVFoundation, and QuartzCore APIs. The separate development lab also uses Metal.

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

## Scope of the safeguards

Saving the baseline before writing, using a separate helper, checking ownership, and keeping an interrupted session's record provide multiple opportunities to restore it. They cannot provide an absolute guarantee through simultaneous app/helper termination, an operating-system failure, or a disconnected display. In a simultaneous failure, restoration may wait until Headroom is reopened with that display available.

This design is intended for everyday brightness adjustment. Instrumented color accuracy, maximum physical luminance, battery impact, and broad hardware compatibility remain validation work; see the [matrix](../VALIDATION.md#remaining-compatibility-work).
