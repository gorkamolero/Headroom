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

## Local data and removal

Headroom saves slider preferences in macOS user preferences. Its local support data is:

| Location | Purpose |
| --- | --- |
| `~/Library/Application Support/Headroom/Recovery` | Per-display original tables and pending recovery records |
| `~/Library/Application Support/HeadroomShared/DisplayLocks` | Coordinates display ownership between Headroom and the development lab |
| `~/Library/Application Support/HeadroomLab/Recovery` | Records from the optional development lab, if it was used |

No recovery data is uploaded. Development logs can include display identifiers; inspect them before sharing.

To remove Headroom, switch off active displays, quit normally, and move the app to the Trash. No service or login item needs uninstalling. Once restoration has completed and no Headroom or lab instance is running, its support folders may also be removed. Keep any pending recovery records until their display has been restored.
