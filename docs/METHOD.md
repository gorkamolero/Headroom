# How Headroom works

For extra brightness, Headroom combines an HDR activation surface with a display transfer-table adjustment. Enabling EDR by itself does not document or guarantee an increase in the brightness of other applications. Headroom 0.5.0 also provides extra dimming by scaling the saved display tables downward, without activating HDR.

## 1. Check the display

The app requires a connected, non-mirrored display. For boost, it reads each `NSScreen`'s potential and current EDR headroom and requires potential headroom greater than 1.01. Current headroom is checked again after activation and while boosting. If the system provides no extra range, boost stops and the menu reports unavailability. The candidate's extra dimming path does not require EDR headroom.

Physical display identity, display mode, and color-profile configuration are recorded. The boost and recovery implementation uses public AppKit, Core Graphics, AVFoundation, and QuartzCore APIs. The separate development lab also uses Metal. Headroom 0.5.0 isolates private APIs in two compatibility adapters: native-brightness control and read-only nits reporting. Its brightness overlay uses public AppKit and SwiftUI controls.

## 2. Make an HDR surface available

For a display entering boost above a factor of 1, `HDRCarrier` creates a transparent 5 × 5 point nonactivating panel with a 1 × 1 point `AVPlayerLayer`. It loads this project's own 64 × 64 pixel black HLG sample, encoded as 10-bit HEVC. The player is muted and remains at rate zero: there is no play, seek, loop, screen capture, or continuous rendering routine.

Preparation waits for the asset, a displayable first frame, and current EDR headroom above 1.01. It proceeds immediately when all are ready; if headroom is not yet available, a temporary 40 ms timer checks again within an eight-second preparation timeout. There is no fixed startup delay. Current headroom is checked again before starting any table change. The sample's [generation command and provenance](../Sources/DisplayActivation/Resources/RESOURCE-ORIGIN.md) are included in the source.

Extra dimming below a factor of 1 skips HDR preparation and uses only the table adjustment and recovery helper.

The earlier lab renders a single EDR-enabled Metal frame instead. The paused carrier is the menu app's present implementation; those paths must be validated separately.

## 3. Scale from an immutable baseline

A separate `DisplayGuardian` process acquires a lock for the physical display, checks pending recovery records, reads the original RGB tables and their actual sample count, and durably saves them before the first write.

For a requested multiplier `m`, each channel's proposed sample is:

```text
proposed[i] = original[i] × m
```

Every adjustment uses `original`, never the preceding result. The candidate accepts factors from 0.1 to 2.0: values below 1 dim the saved tables, 1 is the unchanged baseline, and values above 1 request boost. Boost is further limited by potential and current headroom. Default selections vary by display type; the app remembers a changed selection per display. A factor of 0.1 is a table scale, not a measured 10% luminance level.

Apple documents transfer-table samples between 0 and 1. Proposed samples above 1 use behavior outside that documented range. On the test machine, readback was capped at 1 even when larger values were submitted. The visible result depends on the display pipeline; the API result cannot establish physical brightness or final highlight clipping. A factor of 2.0 therefore must not be advertised as doubling brightness. See [Apple sources](../APPLE-SOURCES.md) and [validation](../VALIDATION.md).

## 4. Keep recovery independent

The menu app sends a heartbeat every second and renews a 30-second lease every ten seconds. The helper starts restoration after five seconds without a heartbeat, lease expiry, closed parent input, an explicit stop, or handled termination. The parent also watches helper replies; if the helper freezes, it runs a bounded termination and recovery sequence.

Normal disable and quit restore the original tables and read them back before retiring the recovery record. Recovery accepts a maximum sample difference of 0.0005; the recorded restoration runs achieved 0.0. A shared lock prevents another Headroom instance or the lab from capturing an already boosted table as a new baseline.

Hardware brightness selected with Headroom's keyboard control persists after disable or quit. The recovery helper owns temporary gamma adjustments; it does not roll back the user's ordinary hardware-brightness setting.

Recovery checks the physical display and its configuration. If the display is disconnected, its profile has changed, or another transform is active, Headroom retains its record and blocks a new session rather than blindly overwriting the current display state. Reopening the app retries pending recovery for connected displays.

Sleep, display sleep, lock, wake, and relevant display changes end or pause sessions. A new boost requires explicit enable. No privileged helper, login item, firmware change, or permanent background daemon is installed.

## Brightness keys and extra dimming — 0.5.0

This feature is included in 0.5.0. Brightness-key handling starts automatically with the app. Headroom requests Accessibility permission when needed and reports its status in the menu. Once allowed, a Core Graphics event tap handles brightness media keys; other input passes through and is not recorded. Screen Recording is not required.

On a supported display, Headroom consumes brightness-key events across all three ranges and directly sets the native hardware level in the normal range. Holding Up reaches hardware maximum and continues into boost. Holding Down reaches a native setting of 0.01, then continues into software dimming while leaving the backlight at that setting. Neither boundary requires releasing the key or pressing it again. The 0.01 floor is 1% of the native slider range, not 1% of measured luminance. If hardware brightness is already 0, Up raises it through the native setter; Down leaves it off. Scaling color tables cannot light a backlight that is off.

Holding Down reduces boost toward 1; holding Up reduces extra dimming toward 1. Reaching 1 restores the original tables before the held key resumes hardware-brightness changes. Native writes are serialized and read back before a queued action can enter an extra range. Absolute adjustments in the same range can be coalesced; start and restoration boundaries retain their order. Option + Shift selects smaller increments. Pending key actions are discarded on sleep or quit. Both extra ranges use the same helper, saved baseline, lease, and restoration checks.

Media-key events contain no physical display UUID. Headroom targets the connected built-in display, or the primary display when no built-in display is connected. Independent menu controls remain available for every supported display. Keyboard handling pauses while Lunar runs, without quitting or changing Lunar. This feature does not add external-monitor DDC or automatic brightness control.

Headroom presents one panel labeled Display −, Display, or Display + across supported extra dim, hardware, and extra bright key adjustments, using `NSGlassEffectView` and a native SwiftUI slider on macOS 26 or later, with a compatible vibrancy panel on older systems. It follows the native appearance with a white bar, evenly spaced tick marks, and sun icons, then fades after the key press. Existing ticks at the two range boundaries are taller. Held keys pause for 350 ms at a confirmed boundary before continuing; a fresh press or reversal skips the pause. The bar represents a control position, not measured luminance or a claim of twice the brightness. Supported events are consumed so macOS does not also display its ordinary brightness indicator. Status and errors stay in Headroom's menu.

`NormalBrightnessReader` dynamically loads `DisplayServicesGetBrightness` and `DisplayServicesSetBrightness`. It accepts finite native levels in 0–1, reports API success separately from settled readback, and detects external hardware-brightness changes during a keyboard-controlled gamma session. A missing adapter, failed write, or unavailable reading prevents Headroom from owning normal brightness control; ordinary keys then fall back to macOS. Neither function changes the display preset or automatic-brightness preference. The legacy system OSD was ignored on the test OS, and Apple's modern banner service refused access without its private entitlement, so Headroom uses its own panel with public controls. No Lunar code or assets are included. See [Apple sources](../APPLE-SOURCES.md#brightness-keys--050).

Physical media-key repetition and restoration handoff remain separate live checks; [validation](../VALIDATION.md) records results by build. The 0.5.0 packaged app reuses a certificate-bound community signing identity. Moving from an older ad-hoc build requires one permission refresh; a subsequent signed update retained permission in the recorded test. Source-built ad-hoc copies can still require new approval after rebuilding. Headroom keeps normal macOS permission and signature checks.

## Estimated nits and HDR capacity — local build 20

The native reference is macOS's reported `NitsPhysical`, read from one per-display CoreBrightness `StatusInfo` response. The field's name does not mean an optical measurement of post-gamma desktop pixels. `EDRState.SDR` is never substituted for current native brightness because it can stay fixed while the native readings change; it supplies only its own reference basis for an HDR capacity bound. Per-display identity, Objective-C signatures, numeric types, and ranges are checked before a reading is used. CoreBrightness is a private implementation detail, independently inspected on the test Mac; unsupported versions or missing native nits fall back to `DisplayServicesGetLinearBrightness × PresetMaxSDRLuminance` read under a nonblocking MonitorPanel lock. No model-specific SDR maximum or HDR maximum substitutes for a missing native reference.

Reads run on a serial background queue, with at most one refresh pending per display. The HUD and menu consume only fresh cached results. No brightness, preset, automatic-brightness, or display preferences are changed by these readers. Unknown/stale readings and preparing, stopping, or recovery states display **— nits**.

For confirmed extra dimming, the estimate applies the inverse sRGB response to the acknowledged table factor `m`: `m / 12.92` below or at 0.04045, otherwise `((m + 0.055) / 1.055)^2.4`. The result multiplies the native nits reference. Apple documents Display P3's sRGB transfer function, but this is still an assumption about the complete display pipeline, not a calibration. Normal and dimmed estimates use **≈**.

During boost, build 20 calculates a prediction under an **explicit extended-sRGB hypothesis**. Let `B` be the live native nits reference, and `f` the table-write factor acknowledged by `DisplayGuardian`, never a queued slider target. The model treats that factor as an extended encoded RGB white value, with normal white at 1, and assumes it survives into the EDR pipeline without clipping before decoding. For `f ≥ 1`:

```text
capacity = min(HDR limit, B × current public EDR headroom,
               reported EDR SDR reference × reported available headroom when available)
predicted nits = B × ((f + 0.055) / 1.055)^2.4
estimated nits = min(predicted nits, capacity)
```

The curve follows the extended sRGB decoding formula documented in the [W3C colour-conversion reference](https://www.w3.org/TR/css-color-4/#color-conversion-code). Apple documents [extended sRGB values above 1](https://developer.apple.com/documentation/coregraphics/cgcolorspace/extendedsrgb) and [Display P3's sRGB transfer function](https://developer.apple.com/documentation/coregraphics/cgcolorspace/displayp3). Those definitions motivate the assumption; they do not establish that a Core Graphics gamma-table write follows it. Apple's table API documents inputs from 0 to 1, and the test Mac's normalized readback clamps entries above 1. Neither that readback nor the helper's acknowledgement verifies the assumed optical response. Gamma clipping, colour processing, and the display's own brightness limits may change actual output.

The two headroom ratios keep their own reference bases. Public current headroom comes from a freshly resolved, display-matched `NSScreen`. CoreBrightness's raw `Headroom` remains diagnostic only because it can track a request rather than available output. Apple's [tone-mapping documentation](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping) supports the SDR-white × current-headroom capacity relationship; it does not map gamma adjustments to luminance. The HDR limit comes from system telemetry or the active preset, never a hardcoded 1600-nit maximum.

The overlay and menu label the prediction **≈… nits est.** Tooltip and accessibility text identify the uncalibrated assumption; the tooltip also gives the independent HDR ceiling. The model joins the native reading at factor 1. Increasing the factor changes the prediction until capacity caps it; the slider's endpoint is not mapped to 1600 nits or any other panel maximum. A displayed 1600-nit estimate is not proof of attained or sustained full-screen brightness. Invalid inputs, missing capacity, or a capacity below the native reference produce **— nits**. Physical luminance, colour accuracy, and battery impact remain unmeasured. Build-specific checks and installation status are recorded separately in [VALIDATION.md](../VALIDATION.md); these features are included in the 0.5.0 community beta.

### Earlier readouts

Build 19's capacity-only **HDR ≤… nits** readout is superseded by build 20's explicitly labelled prediction. Build 19 removed build 18's interpolation from slider position to an HDR ceiling. That interpolation remains removed: build 20 uses the stated transfer-response model and keeps capacity as a separate bound.

## Scope of the safeguards

Saving the baseline before writing, using a separate helper, checking ownership, and keeping an interrupted session's record provide multiple opportunities to restore it. They cannot provide an absolute guarantee through simultaneous app/helper termination, an operating-system failure, or a disconnected display. In a simultaneous failure, restoration may wait until Headroom is reopened with that display available.

This design is intended for everyday brightness adjustment. Instrumented color accuracy, maximum physical luminance, battery impact, and broad hardware compatibility remain validation work; see the [matrix](../VALIDATION.md#remaining-compatibility-work).
