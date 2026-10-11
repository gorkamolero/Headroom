# How Headroom works

For extra brightness, Headroom combines an HDR activation surface with a display transfer-table adjustment. Enabling EDR by itself does not document or guarantee an increase in the brightness of other applications. The local 0.5.0 candidate also provides extra dimming by scaling the saved display tables downward, without activating HDR.

## 1. Check the display

The app requires a connected, non-mirrored display. For boost, it reads each `NSScreen`'s potential and current EDR headroom and requires potential headroom greater than 1.01. Current headroom is checked again after activation and while boosting. If the system provides no extra range, boost stops and the menu reports unavailability. The candidate's extra dimming path does not require EDR headroom.

Physical display identity, display mode, and color-profile configuration are recorded. The boost and recovery implementation uses public AppKit, Core Graphics, AVFoundation, and QuartzCore APIs. The separate development lab also uses Metal. The local 0.5.0 candidate isolates private APIs in two compatibility adapters: native-brightness control and read-only nits reporting. Its brightness overlay uses public AppKit and SwiftUI controls.

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

Hardware brightness selected with the candidate's keyboard control persists after disable or quit. The recovery helper owns temporary gamma adjustments; it does not roll back the user's ordinary hardware-brightness setting.

Recovery checks the physical display and its configuration. If the display is disconnected, its profile has changed, or another transform is active, Headroom retains its record and blocks a new session rather than blindly overwriting the current display state. Reopening the app retries pending recovery for connected displays.

Sleep, display sleep, lock, wake, and relevant display changes end or pause sessions. A new boost requires explicit enable. No privileged helper, login item, firmware change, or permanent background daemon is installed.

## Brightness keys and extra dimming — next beta

This feature is in development and is not included in the 0.4.0 release. Brightness-key handling starts automatically with the app. Headroom requests Accessibility permission when needed and reports its status in the menu. Once allowed, a Core Graphics event tap handles brightness media keys; other input passes through and is not recorded. Screen Recording is not required.

On a supported display, Headroom consumes brightness-key events across all three ranges and directly sets the native hardware level in the normal range. Holding Up reaches hardware maximum and continues into boost. Holding Down reaches a native setting of 0.01, then continues into software dimming while leaving the backlight at that setting. Neither boundary requires releasing the key or pressing it again. The 0.01 floor is 1% of the native slider range, not 1% of measured luminance. If hardware brightness is already 0, Up raises it through the native setter; Down leaves it off. Scaling color tables cannot light a backlight that is off.

Holding Down reduces boost toward 1; holding Up reduces extra dimming toward 1. Reaching 1 restores the original tables before the held key resumes hardware-brightness changes. Native writes are serialized and read back before a queued action can enter an extra range. Absolute adjustments in the same range can be coalesced; start and restoration boundaries retain their order. Option + Shift selects smaller increments. Pending key actions are discarded on sleep or quit. Both extra ranges use the same helper, saved baseline, lease, and restoration checks.

Media-key events contain no physical display UUID. Headroom targets the connected built-in display, or the primary display when no built-in display is connected. Independent menu controls remain available for every supported display. Keyboard handling pauses while Lunar runs, without quitting or changing Lunar. This feature does not add external-monitor DDC or automatic brightness control.

Headroom presents one panel labeled Display −, Display, or Display + across supported extra dim, hardware, and extra bright key adjustments, using `NSGlassEffectView` and a native SwiftUI slider on macOS 26 or later, with a compatible vibrancy panel on older systems. It follows the native appearance with a white bar, evenly spaced tick marks, and sun icons, then fades after the key press. Existing ticks at the two range boundaries are taller. Held keys pause for 350 ms at a confirmed boundary before continuing; a fresh press or reversal skips the pause. The bar represents a control position, not measured luminance or a claim of twice the brightness. Supported events are consumed so macOS does not also display its ordinary brightness indicator. Status and errors stay in Headroom's menu.

`NormalBrightnessReader` dynamically loads `DisplayServicesGetBrightness` and `DisplayServicesSetBrightness`. It accepts finite native levels in 0–1, reports API success separately from settled readback, and detects external hardware-brightness changes during a keyboard-controlled gamma session. A missing adapter, failed write, or unavailable reading prevents Headroom from owning normal brightness control; ordinary keys then fall back to macOS. Neither function changes the display preset or automatic-brightness preference. The legacy system OSD was ignored on the test OS, and Apple's modern banner service refused access without its private entitlement, so Headroom uses its own panel with public controls. No Lunar code or assets are included. See [Apple sources](../APPLE-SOURCES.md#brightness-keys--next-beta).

Physical media-key repetition and restoration handoff remain separate live checks; [validation](../VALIDATION.md) records results by build. Updated ad-hoc builds may need Accessibility approval again because their code identity changes; Headroom keeps the normal macOS permission and signature checks.

## Estimated nits — local build 18

The overlay and per-display menu show approximate white luminance. A separate read-only `DisplayLuminanceReader` adapter dynamically loads `DisplayServicesGetLinearBrightness` and MonitorPanel's active-preset getters. It validates private Objective-C method signatures before calling them and takes only a nonblocking manager lock, with a matching unlock. The SDR and HDR limits come from the same active-preset dictionary, with linear brightness read during that access; independently cached preset values are never combined. Missing symbols, changed signatures, a busy manager, or invalid native readings produce no estimate. Invalid HDR metadata leaves the native and dimmed estimates available but prevents the boost model. These private APIs have no public compatibility guarantee and do not change brightness, presets, or automatic-brightness settings.

The native calculation is `linear brightness × PresetMaxSDRLuminance`. The SDR maximum comes from that display's active preset; no model-specific maximum or HDR maximum is substituted. The readout refreshes while its UI is visible: every 100 ms for the overlay, and with the menu's refresh timer.

For confirmed extra dimming, the estimate applies the inverse sRGB response to the acknowledged table factor `m`: `m / 12.92` below or at 0.04045, otherwise `((m + 0.055) / 1.055)^2.4`. The result multiplies the native nits reference. Apple documents Display P3's sRGB transfer function, but this is still an assumption about the complete display pipeline, not a calibration. Tooltip text explains that limitation. A table factor of 0.5 therefore is not presented as a measured 50% luminance ratio.

Build 18 adds an uncalibrated model for confirmed extra brightness. Define:

- `B`: the live native nits reference calculated above.
- `H`: the display's **current** EDR headroom, never potential headroom.
- `M`: `PresetMaxHDRLuminance` from the same active preset as the SDR reference.
- `F`: the session's configured maximum table factor (`session.maximumFactor`).
- `f`: the table factor acknowledged by `DisplayGuardian`, not a queued target.

```text
p = clamp((f - 1) / (F - 1), 0, 1)
C = min(M, B × H)
estimated nits = B + p × (C - B)
```

The estimate joins the native reference at a factor of 1 and moves toward capacity `C` as the confirmed adjustment reaches its configured maximum. When current headroom falls, the modeled ceiling falls too. There is no hardcoded display maximum. Apple's [tone-mapping documentation](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping) supports using SDR-white luminance and current EDR headroom to describe available rendering capacity. It does **not** establish this interpolation or the physical response of Headroom's transfer-table changes. `C` is a capacity bound for the model, not proof that Headroom reaches it or sustains it across the full screen. The table factor is never treated as a direct luminance multiplier.

Every numeric label starts with **≈**, and the boost tooltip identifies the value as an uncalibrated model. The label becomes **— nits** when required metadata is unsupported or a session is preparing, stopping, or awaiting recovery. Queued adjustment targets are never used as confirmed nits. No light meter is used; color accuracy, ambient adaptation, sustained full-screen luminance, and physical brightness remain separate validation work. Build 17's earlier native and dimmed estimates intentionally displayed **— nits** during boost; build 18 extends that behavior with the model above. Neither version is included in the public 0.4.0 release.

## Scope of the safeguards

Saving the baseline before writing, using a separate helper, checking ownership, and keeping an interrupted session's record provide multiple opportunities to restore it. They cannot provide an absolute guarantee through simultaneous app/helper termination, an operating-system failure, or a disconnected display. In a simultaneous failure, restoration may wait until Headroom is reopened with that display available.

This design is intended for everyday brightness adjustment. Instrumented color accuracy, maximum physical luminance, battery impact, and broad hardware compatibility remain validation work; see the [matrix](../VALIDATION.md#remaining-compatibility-work).
