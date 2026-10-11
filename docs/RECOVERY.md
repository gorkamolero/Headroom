# Recovery and troubleshooting

## Returning to normal brightness

Switch a display **off** in Headroom to restore its saved original color tables. **Quit Headroom** restores every active display before exiting. A brief “Restoring…” state means the app is waiting for its recovery helper to finish.

In Headroom 0.5.0, the hardware brightness you selected remains at its last setting after disable or quit. Restoration removes temporary gamma adjustments; it does not undo your ordinary brightness selection.

If the menu app crashes, the helper detects the closed connection or missing heartbeat and attempts restoration. If both processes are interrupted, reopen Headroom with the affected display connected. It checks saved recovery records before allowing a new adjustment session.

Do not delete recovery data while a session is active or while recovery needs attention: that data contains the exact tables needed for restoration.

## The menu says extra brightness is unavailable

A display can support EDR without currently having headroom available. Its preset, system brightness, mirroring, macOS behavior, and other display settings can affect availability. Headroom remains off if preparation fails or the current headroom is insufficient. It does not change your display preset or automatic-brightness preference to enable boost.

## The menu says recovery needs attention

Reconnect the same display and reopen Headroom, or choose **More → Turn Off and Retry Recovery**. This waits for active helpers to stop before retrying saved records. If another Headroom copy or Headroom Lab is still open, quit that copy normally first. If another utility is adjusting display colors, pause it through its own controls before retrying Headroom.

A changed profile or a different active transform can prevent Headroom from proving that its saved tables still belong to the current configuration. The app keeps the recovery record rather than overwrite an unrelated adjustment. If the message persists, keep the record and report the displayed error, your display model, and macOS version. Full journals contain display identifiers and should not be posted publicly.

There is no universal “reset everything” action in normal recovery. Resetting all displays to ColorSync defaults is different from restoring the exact original tables captured for one display.

## Brightness keys and extra dimming — 0.5.0

Keyboard control is included in 0.5.0. It starts automatically with Headroom. The app requests Accessibility permission once on first use; allow Headroom under **System Settings → Privacy & Security → Accessibility**. The menu reports when permission is missing. Its switches and sliders remain usable without this permission; Screen Recording is not needed.

Headroom handles supported keys throughout the normal hardware range and both extra ranges. Keep holding Up to enter boost at maximum, or Down to lower the hardware setting to 1% and then enter extra software dimming. No release or second press is needed. Extra dimming leaves the hardware at that setting. This percentage describes the hardware slider, not measured luminance. If hardware brightness is already zero, Up raises it; Down leaves it off.

Holding Down reduces boost; holding Up reduces extra dimming. At the unchanged baseline, Headroom restores the original tables before the held key continues through the normal hardware range. Holding Option + Shift gives smaller steps.

One overlay labelled **Display −**, **Display**, or **Display +** covers the three ranges. It has a bar, evenly spaced ticks, taller boundary ticks, and sun icons. Held keys pause briefly at boundaries. The nits readout is an estimate; **Display +** explicitly marks its uncalibrated prediction with **est.** The bar represents control position, not measured brightness. The menu slider can dim the saved tables to a factor of 0.1 without starting the HDR carrier; this does not mean 10% of physical brightness. Switching the display off restores its original tables from either extra range.

Keys target the built-in display, otherwise the primary display. Use the per-display menu for another screen. If Lunar is running, Headroom pauses keyboard control to avoid both apps handling the same key. Quit Lunar yourself if you want Headroom to handle the keys; Headroom does not close it automatically.

If keys do not enter either extra range, check Accessibility permission and the menu's availability message. An unavailable native-brightness adapter, failed write, or failed read leaves ordinary keys with macOS. Use the display switch to turn off active boost or extra dimming. Quitting Headroom restores the original color tables, preserves your selected hardware brightness, and leaves all keyboard handling to macOS. Sleep and quit discard pending key actions, and existing display restoration safeguards still apply. Build-specific checks and remaining physical-key tests are recorded in [validation](../VALIDATION.md).

## Updating and permissions

The packaged 0.5.0 beta uses one persistent community signing certificate. When upgrading from an ad-hoc copy, macOS may require removing and re-adding Headroom in Accessibility once. Future packages using the same identity are intended to retain access; this was verified across a local update. Rebuilding ad-hoc or using a different certificate changes that identity and can require approval again. No certificate needs to be manually trusted or installed on the receiving Mac.

## Local data and removal

Headroom saves per-display slider preferences in macOS user preferences. Its local support data is:

| Location | Purpose |
| --- | --- |
| `~/Library/Application Support/Headroom/Recovery` | Per-display original tables and pending recovery records |
| `~/Library/Application Support/HeadroomShared/DisplayLocks` | Coordinates display ownership between Headroom and the development lab |
| `~/Library/Application Support/HeadroomLab/Recovery` | Records from the optional development lab, if it was used |

No recovery data is uploaded. Development logs can include display identifiers; inspect them before sharing.

To remove Headroom, switch off active displays, quit normally, and move the app to the Trash. No service or login item needs uninstalling. Once restoration has completed and no Headroom or lab instance is running, its support folders may also be removed. Keep any pending recovery records until their display has been restored.
