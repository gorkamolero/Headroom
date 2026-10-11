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

Run `bash Tests/Integration/build-luminance.sh`, then open the generated `Evidence/nits-build17/NitsHUDCheck.app`. It does not change display settings or request keyboard permission. It checks the production nits reader, live HUD updates without additional key events, a simulated dimming estimate, dismissal, focus, panel reuse, and unchanged display tables. After three seconds it writes `hud-check.json` beside the app and shows the live native reading for a short visual check before quitting automatically. The dimming sample is a calculation test; it does not measure emitted light.
