# Recovery and troubleshooting

## Returning to normal brightness

Switch a display **off** in Headroom to restore its saved original color tables. **Quit Headroom** restores every active display before exiting. A brief “Restoring…” state means the app is waiting for its recovery helper to finish.

If the menu app crashes, the helper detects the closed connection or missing heartbeat and attempts restoration. If both processes are interrupted, reopen Headroom with the affected display connected. It checks saved recovery records before allowing a new boost.

Do not delete recovery data while a session is active or while recovery needs attention: that data contains the exact tables needed for restoration.

## The menu says extra brightness is unavailable

A display can support EDR without currently having headroom available. Its preset, system brightness, mirroring, macOS behavior, and other display settings can affect availability. Headroom remains off if preparation fails or the current headroom is insufficient. It does not silently change your display preset or normal brightness control.

## The menu says recovery needs attention

Reconnect the same display and reopen Headroom, or choose **More → Turn Off and Retry Recovery**. This waits for active helpers to stop before retrying saved records. If another Headroom copy or Headroom Lab is still open, quit that copy normally first. If another utility is adjusting display colors, pause it through its own controls before retrying Headroom.

A changed profile or a different active transform can prevent Headroom from proving that its saved tables still belong to the current configuration. The app keeps the recovery record rather than overwrite an unrelated adjustment. If the message persists, keep the record and report the displayed error, your display model, and macOS version. Full journals contain display identifiers and should not be posted publicly.

There is no universal “reset everything” action in normal recovery. Resetting all displays to ColorSync defaults is different from restoring the exact original tables captured for one display.

## Brightness keys — next beta

Keyboard control is a development feature, not part of the 0.4.0 download. Turn on **Use Brightness Keys** and allow Headroom under **System Settings → Privacy & Security → Accessibility**. The menu switches and sliders remain usable without this permission; Screen Recording is not needed.

Below maximum, macOS handles normal brightness. Release Up at maximum and press it again to enter boost. Down reduces boost and restores the original tables before normal dimming resumes. Holding Option + Shift gives smaller steps. The on-screen multiplier is a setting, not a measurement of screen brightness.

Keys target the built-in display, otherwise the primary display. Use the per-display menu for another screen. If Lunar is running, Headroom pauses keyboard control to avoid both apps handling the same key. Quit Lunar yourself if you want Headroom to handle the keys; Headroom does not close it automatically.

If keys do not enter boost, check Accessibility permission and the menu's availability message. An unavailable native-brightness read also leaves keys with macOS. Turning **Use Brightness Keys** off returns keyboard handling to macOS; use the display switch to turn off any active boost. Sleep and quit discard pending key actions, and existing display restoration safeguards still apply. Actual key interception needs validation with permission enabled.

## Local data and removal

Headroom saves slider preferences in macOS user preferences; the development version also saves whether brightness-key control is enabled. Its local support data is:

| Location | Purpose |
| --- | --- |
| `~/Library/Application Support/Headroom/Recovery` | Per-display original tables and pending recovery records |
| `~/Library/Application Support/HeadroomShared/DisplayLocks` | Coordinates display ownership between Headroom and the development lab |
| `~/Library/Application Support/HeadroomLab/Recovery` | Records from the optional development lab, if it was used |

No recovery data is uploaded. Development logs can include display identifiers; inspect them before sharing.

To remove Headroom, switch off active displays, quit normally, and move the app to the Trash. No service or login item needs uninstalling. Once restoration has completed and no Headroom or lab instance is running, its support folders may also be removed. Keep any pending recovery records until their display has been restored.
