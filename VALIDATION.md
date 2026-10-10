# Validation

Recorded on 10 October 2026. This record separates the current menu app from the earlier Metal lab and separates API results from physical measurements. The repository contains a [sanitized results summary](docs/validation-results.json); raw local logs, device identifiers, and recovery tables are excluded.

## Test environment

| Item | Recorded condition |
| --- | --- |
| Mac | Apple Silicon M5 Pro MacBook Pro |
| Display | Built-in Liquid Retina XDR, 3024 × 1964 |
| macOS | 27.0.1, build 26A434 |
| Transfer tables | 1,024 samples per RGB channel |
| Automatic brightness | Enabled during the menu scale sweep |
| Luminance/color instrument | None |

The deployment target is macOS 13. That is a build target, not evidence that every supported OS release has been tested. External displays, Intel Macs, and other Apple Silicon models have no recorded live pass.

## Completed checks

### 0.5.0 brightness-key candidate

The local 0.5.0 candidate passed **58 automated tests**: the existing 34 recovery/core tests and 24 new media-key parser, policy, and gesture-sequence tests. The new cases cover a deliberate extra Up press at normal maximum, normal-range passthrough, held-key behavior, fine increments, key-up ownership, restoration before handing held Down back to macOS, unsupported modifiers, and invalid readings.

The release build and deep/strict ad-hoc signature verification passed. The isolated, read-only normal-brightness getter returned `1.0` successfully on the built-in display. Review also found and corrected stale-threshold activation and the held-Down handoff. These checks do **not** establish that global interception, native repeat handoff, or the visible indicator works end to end: live verification requires Accessibility permission. The public 0.4.0 release remains unchanged while that check is pending.

### Existing 0.4.0 evidence

| Check | Result and scope |
| --- | --- |
| Core automated tests | 34 tests passed for 0.4.0. Covers table validation/scaling, recovery ownership, identity/configuration checks, locks, durable records, leases, and configuration changes during recovery. |
| Menu activation and renewal | Native menu remained open for 35.22 seconds while the same session survived lease renewal. No recorded error; active factor approximately 1.511. |
| Menu scale sweep | Requested factors 1.75 and 2.0 were applied and read back. The selected intermediate factor was restored afterward. |
| Menu disable after scale sweep | All original RGB samples matched saved Float32 baseline exactly: maximum difference 0.0. |
| 0.4.0 guardian fault scenarios | Stop, closed parent input, lost heartbeat, fixed deadline, SIGTERM, and SIGKILL followed by recovery all finished with exact baseline readback and no remaining journal. Tested with the release helper at factor 1.01. In the SIGKILL case the original tables were already active when recovery ran; no recovery write was needed. |
| Lab application fault scenarios | Forced termination of the app, forced termination of the helper, and a frozen helper followed by watchdog recovery all finished with exact baseline readback. |
| Perceived brightness and restoration | In the earlier Metal lab, the observer reported brighter ordinary desktop content and a return after the combined trial. |
| Near-white steps | The observer distinguished 80%, 90%, and 100% gray patches in the earlier combined lab trial at approximately 1.216. This does not validate color accuracy or the menu app at maximum scale. |

The paused HDR carrier and the lab's single-frame Metal surface are different activation methods. Historical lab results support the recovery design but do not replace live tests of every menu-app condition.

## What the numbers mean

The current EDR value is a rendering allowance reported by macOS. A transfer-table readback reports the API's stored state. Neither proves physical luminance gain. Apple DTS has reproduced successful writes and matching readback with no visible effect on another Mac/OS combination; see [Apple sources](APPLE-SOURCES.md).

During the menu scale sweep, table readback capped values at 1.0. At factor 1.75, 439 of 1,024 samples per channel formed the upper plateau; at factor 2.0, 512 did. This establishes the API's clamping behavior. It does not resolve final compositor highlight clipping or color accuracy. The slider must not be described as “twice as bright.”

No brightness in nits, contrast ratio, color error, battery-life change, or sustained total GPU power has been measured. A ten-second **lab-only** sample used approximately 0.276% of one CPU core for the lab and 0.103% for the helper, with approximately 73.9 MB and 12.7 MB resident memory. It excluded WindowServer and display power and is not a performance claim for the menu release.

## Current menu-app sample

The installed 0.4.0 app started off, rejected a duplicate launch cleanly, and then sustained the saved boost through a 35.02-second observation with the same session surviving renewal. With the menu closed, the app averaged approximately **0.200% of one CPU core** and used **59.4 MiB** resident memory; its helper averaged **0.086%** and used **12.4 MiB**. These are short process samples from CPU-time counters, excluding WindowServer, total GPU work and display power. They are not a battery-life or sustained-load benchmark.

## Packaging and remote build status

The 0.4.0 beta archive was extracted and its app signature verified again. Both executables contain only system-library dependencies, target arm64/macOS 13, and contain no developer home-directory paths. The installed app uses the verified final icon assets. The uploaded archive's SHA-256 matches the local package: `47c3f76d71d7e8fd12e3a6531047b1e18dba062b21f67e35efd771d9a6482f8d`.

Local tests and packaging passed. The GitHub Actions workflow passed actionlint 1.7.12, but [the remote run](https://github.com/gorkamolero/Headroom/actions/runs/38074730282) returned `startup_failure` before creating any jobs. GitHub supplied no detailed reason or runner logs, so remote CI is not verified. This is not recorded as a passing build. The beta remains ad-hoc signed; Developer ID signing and notarization have not occurred.

## Remaining compatibility work

| Area | Status |
| --- | --- |
| Physical sleep/wake, display sleep, lock/unlock | Handling implemented; complete live lifecycle matrix pending |
| Disconnection/reconnection and changed display arrangement | Identity/configuration guards implemented; physical multi-display tests pending |
| Multiple displays and external XDR displays | Independent sessions implemented; live verification pending |
| Unsupported or mirrored display | Availability guards implemented; live hardware cases pending |
| HDR video and fullscreen transitions | Pending |
| Spaces and Stage Manager | Pending |
| Night Shift and scheduled transitions | Pending |
| True Tone and ambient changes | Pending |
| Automatic brightness off/on transitions | Pending; sweep kept it enabled |
| Other color/brightness utilities | Ownership conflicts are detected where readback differs; coexistence matrix pending |
| Sustained CPU/GPU and battery impact | Pending for the menu release |
| Instrumented luminance and color clipping | Pending |
| Developer ID signing, notarization, quarantined-download launch | Not part of 0.4.0: the maintainer selected a beta/source release. Downloaded ad-hoc builds may be blocked by macOS. |

## Reproducing a useful comparison

Keep the room, display preset, system brightness, content, and window sizes fixed. Compare off/on/off using the same ordinary white document, near-white steps, neutral gray ramp, and color patches. Record the requested scale separately from perceived brightness. Verify restored transfer tables after switching off, and record any visible mismatch separately.

For each new hardware/OS combination, verify normal restoration before crash scenarios. Fault-injection tools are development utilities and should be run deliberately, with no other display-adjustment session active. A complete performance test must include compositor work and display power, not only the Headroom process.

Community beta status is appropriate while this matrix remains incomplete. Notarization will establish Apple's distribution checks; it will not certify display compatibility or validate unmeasured brightness claims.
