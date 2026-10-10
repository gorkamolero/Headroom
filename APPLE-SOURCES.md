# Apple sources

Reviewed on 10 October 2026. Headroom is independently implemented with Apple frameworks, its own generated HDR sample, documentation, and local experiments. Reference-app behavior was inspected during research; no Lunar code or assets are included. Release 0.4.0 uses no private macOS APIs. The local 0.5.0 candidate isolates two private integrations behind compatibility adapters: reading normal brightness and drawing macOS's own brightness indicator.

## Display behavior

- [Determining support for EDR values](https://developer.apple.com/documentation/metal/determining-support-for-edr-values): potential headroom above 1 indicates EDR support; current headroom must be checked separately. Capability does not mean extra range is presently available.
- [Performing your own tone mapping](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping): SDR white corresponds to a component value of 1, and EDR rendering must account for current headroom. This does not promise brighter content in other applications.
- [CAMetalLayer.wantsExtendedDynamicRangeContent](https://developer.apple.com/documentation/quartzcore/cametallayer/wantsextendeddynamicrangecontent): used by the earlier Metal experiment. The menu app uses the paused HDR carrier described in [the method](docs/METHOD.md).
- [Reference EDR headroom](https://developer.apple.com/documentation/appkit/nsscreen/maximumreferenceextendeddynamicrangecolorcomponentvalue): reference rendering capability is distinct from current and potential headroom.
- [CGSetDisplayTransferByTable](https://developer.apple.com/documentation/coregraphics/cgsetdisplaytransferbytable(_:_:_:_:_:)): specifies RGB gamma tables, with documented samples in the 0–1 range. Headroom's scaled values above 1 are outside that range even though the function itself is public.
- [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services): provides table capacity, original samples, and actual returned sample count. Headroom captures these before changing the display.
- [CGDisplayRestoreColorSyncSettings](https://developer.apple.com/documentation/coregraphics/cgdisplayrestorecolorsyncsettings()): restores ColorSync defaults for all displays. Headroom's normal recovery instead restores the captured tables for the affected display.

Apple DTS [reproduced successful transfer-table writes and matching readback without a visible change](https://developer.apple.com/forums/thread/819331) on an M5 Max running macOS 26.3.1, including built-in and external displays. The latest Apple response visible at review still described the reported bugs as open and under investigation. This establishes why readback alone is insufficient; it does not prove that every later OS release or every Mac has the same behavior. Other participants' reports about automatic brightness and HDR interactions are compatibility test leads, not verified Headroom results.

## Brightness keys — next beta

- [CGEvent.tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)): installs the event tap used to handle brightness media keys. Other events pass through.
- [CGGetEventTapList](https://developer.apple.com/documentation/coregraphics/cggeteventtaplist(_:_:_:)): reports tap ownership, enabled state, options and event mask. This was used to verify the running GUI's active session tap with only system-defined events selected.
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) and [Apple's Accessibility permission instructions](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac): the user grants permission before keyboard interception can operate. This does not require Screen Recording.
- [Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/): distinguishes passive event listening, which requires Input Monitoring, from an active filter, which requires Accessibility. Headroom uses an active filter so a boost adjustment can consume its brightness event.

`NormalBrightnessReader` dynamically resolves `DisplayServicesGetBrightness` to read normal display brightness and decide whether an extra Up press can start boost. This function is private and has no public Apple API contract. Failed reads prevent automatic entry into boost. Headroom does not call a native brightness setter or override automatic brightness. The existing transfer-table and recovery path supplies the boost.

`NativeBrightnessOSD` dynamically loads the private OSD framework and validates the `OSDManager` runtime method signatures before requesting macOS's brightness indicator. This integration only draws the indicator; it does not set brightness. Missing or incompatible methods leave the indicator unavailable, with no custom panel fallback. The bar represents Headroom's boost range, not measured luminance. These private integrations are independently implemented, and neither has a supported public Apple API contract.

Accessibility approval and an enabled brightness-only session tap were verified for the running GUI. A separate shell-launched diagnostic was attributed to Codex and reported its own untrusted context; it did not describe the GUI's permission state. Physical key repetition, restoration handoff and the visible native indicator still need end-to-end validation.

## Lifecycle and distribution

- [Display reconfiguration callbacks](https://developer.apple.com/documentation/coregraphics/cgdisplayreconfigurationcallback): display changes require reconciliation; an old numeric display ID is not sufficient for recovery.
- [NSWorkspace sleep notifications](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification), [wake notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification), and [display sleep notifications](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification): system and display sleep are separate lifecycle events.
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution): describes the Developer ID signing and notarization workflow for software distributed with Apple's checks. Headroom 0.4.0 instead provides source and an ad-hoc beta: that signature supplies neither a Developer ID identity nor an Apple notarization ticket, and downloaded copies may be blocked by macOS.
- [TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements): explains how a designated requirement identifies code across versions. An ad-hoc signature is tied to a particular build, so an updated beta may need Accessibility approval again. Headroom does not weaken this identity check or modify permission records.

The installed SDK headers were also checked for table range/sample count, EDR properties, and all-display ColorSync restoration behavior. These references describe API contracts. Actual test results and remaining checks are in [VALIDATION.md](VALIDATION.md).
