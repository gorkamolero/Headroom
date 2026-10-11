# Unified brightness-key integration trial

This development harness compiles the production `BrightnessKeyController`, `BoostSession`, `BrightnessHUD`, and compatibility adapter. It feeds `BrightnessKeyEvent` values directly into the controller; it does not synthesize operating-system keyboard input and does not change Accessibility permission. The real native brightness API, real display tables, real guardian, and real HUD are used.

Build the harness and its production dependencies:

```sh
Tests/Integration/build.sh
```

Run only after explicitly stopping Headroom and Lunar and confirming the display has been restored. The external watchdog also refuses to start while either app is running. Use a fresh output directory for each trial:

```sh
Evidence/unified-keys/Watchdog \
  "$PWD/Evidence/unified-keys/UnifiedKeysHarness.app/Contents/MacOS/UnifiedKeysHarness" \
  "$PWD/Evidence/unified-keys/run-01"
```

The watchdog captures native brightness, gamma tables, and display identity before starting the harness. It limits the harness to 100 seconds, terminates a stuck harness, waits for guardian restoration, and verifies/restores the original native brightness and tables. A saved baseline remains in the output directory for recovery evidence. Restoration never applies a baseline to a different display or display configuration.

The harness checks native-to-dim, dim-to-native, native-to-boost, boost-to-native, independent 30 Hz held-Up input with native/gamma samples before key-up (native, cold boost including a 750 ms hold, and active boost), queued repeats, release, 100 alternating direction presses, canceled writes with late repeats, all four held range-boundary pauses with live labels/markers and nonblocking repeats, fresh-press/reversal bypass, native-setter failure, cleared-snapshot restoration, menu dimming before unsupported native fallback, event consumption, real table readback, and visibility of the production HUD window. It records an in-process final restoration; the independent watchdog repeats the restoration check. Screen-parameter notifications compare the same identity, frame, scale, mirroring, and main-display fields used by the app delegate. Only genuine configuration changes cancel queued work; both notification and configuration-change counts are recorded. App-window visibility is not a pixel comparison. This trial does not validate the physical keyboard event tap, subjective brightness, luminance in nits, or battery use.

Outputs include `harness-result.json`, `watchdog-result.json`, `harness.log`, and the private `baseline.json`. Baselines contain display identifiers and full original tables; do not publish them as public release assets.

## Read-only nits overlay check

Run `bash Tests/Integration/build-luminance.sh`, then open the generated `Evidence/nits-build20/NitsHUDCheck.app`. It does not change display settings or request keyboard permission. It checks the production nits reader, live HUD updates without additional key events, simulated dimming and boost estimates, reduced headroom, dismissal, focus, panel reuse, and unchanged display tables. After four seconds it writes `hud-check.json` beside the app and shows the live native reading for a short visual check before quitting automatically. The dimming and boost samples are calculation tests; they do not measure emitted light.

## Bounded live nits session

`bash Tests/Integration/build-luminance-session.sh` builds a focused production-session trial and the existing external watchdog. After quitting Headroom and Lunar and confirming restoration, run:

```sh
Evidence/nits-session/Watchdog \
  "$PWD/Evidence/nits-session/LuminanceSession.app/Contents/MacOS/LuminanceSession" \
  "$PWD/Evidence/nits-session/run-01"
```

Use a fresh output directory for each run. This briefly applies factors 1.1 and 1.2, checks actual table readback and acknowledged nits updates, then restores. It limits the active trial to 20 seconds and verifies unavailable transitional readings, native-brightness preservation, exact original gamma restoration, and no remaining journals. The external watchdog repeats recovery and native readback. `luminance-session-result.json` contains the model inputs and checks; this is not a photometer test. Private baseline and diagnostic logs stay local.
