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

The initial local build is ad-hoc signed. Developer ID signing and notarization are still required before the planned downloadable community release. Headroom has recovery safeguards, but this beta does not promise identical behavior on every display or immunity from every OS failure.
