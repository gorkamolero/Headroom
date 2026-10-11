import XCTest
@testable import DisplayCore

final class BrightnessKeysTests: XCTestCase {
    private let shift: UInt64 = 1 << 17
    private let control: UInt64 = 1 << 18
    private let option: UInt64 = 1 << 19
    private let command: UInt64 = 1 << 20

    private func mediaData(key: Int = 2, state: Int = 10, repeated: Bool = false) -> Int {
        (key << 16) | (state << 8) | (repeated ? 1 : 0)
    }

    private func event(
        _ direction: BrightnessDirection = .up,
        phase: BrightnessKeyPhase = .down,
        repeated: Bool = false,
        fine: Bool = false,
        unsupported: Bool = false
    ) -> BrightnessKeyEvent {
        .init(direction: direction, phase: phase, isRepeat: repeated, fine: fine, hasUnsupportedModifiers: unsupported)
    }

    private func action(
        _ event: BrightnessKeyEvent,
        state: BrightnessBoostState = .off,
        factor: Double = 1,
        ceiling: Double = 2,
        normal: Double? = 1,
        available: Bool = true,
        dimmingAvailable: Bool = false,
        mode: BrightnessAdjustmentMode? = nil,
        nativeAvailable: Bool = true
    ) -> BrightnessKeyAction {
        BrightnessKeyPolicy.action(event: event, state: state, factor: factor, ceiling: ceiling,
                                   normalBrightness: normal, available: available,
                                   dimmingAvailable: dimmingAvailable, mode: mode,
                                   nativeAvailable: nativeAvailable)
    }

    private func route(
        _ event: BrightnessKeyEvent,
        through sequence: inout BrightnessKeySequence,
        state: BrightnessBoostState = .off,
        factor: Double = 1,
        normal: Double? = 1,
        dimmingAvailable: Bool = true,
        mode: BrightnessAdjustmentMode? = nil,
        nativeAvailable: Bool = true
    ) -> BrightnessKeyAction {
        sequence.route(event: event, state: state, factor: factor, ceiling: 2,
                       normalBrightness: normal, available: true,
                       dimmingAvailable: dimmingAvailable, mode: mode,
                       nativeAvailable: nativeAvailable)
    }

    func testMediaKeyParserDistinguishesDirectionReleaseAndRepeat() {
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(), modifierBits: 0), event())
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(key: 3), modifierBits: 0), event(.down))
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(state: 11), modifierBits: 0), event(phase: .up))
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(repeated: true), modifierBits: 0), event(repeated: true))
    }

    func testParserIgnoresOrdinaryKeysVolumeKeysAndMalformedStates() {
        XCTAssertNil(BrightnessKeyEvent.parse(subtype: 0, data1: mediaData(), modifierBits: 0))
        for key in [0, 1, 7, 16, 65535] {
            XCTAssertNil(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(key: key), modifierBits: 0))
        }
        for state in [0, 9, 12, 255] {
            XCTAssertNil(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(state: state), modifierBits: 0))
        }
        XCTAssertNil(BrightnessKeyEvent.parse(subtype: 8, data1: -1, modifierBits: 0))
    }

    func testFineModifiersIgnoreCapsLockAndFunctionFlags() {
        let capsAndFunction: UInt64 = (1 << 16) | (1 << 23)
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(), modifierBits: capsAndFunction), event())
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(), modifierBits: shift | option | capsAndFunction),
                       event(fine: true))
    }

    func testOtherModifierCombinationsAreRecognizedButPassedThrough() {
        for modifiers in [shift, control, option, command, shift | control, control | option,
                          shift | option | control, shift | option | command] {
            let parsed = BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(), modifierBits: modifiers)
            XCTAssertEqual(parsed, event(unsupported: true))
            for state in [BrightnessBoostState.off, .preparing, .on, .stopping, .unavailable] {
                XCTAssertEqual(action(parsed!, state: state, factor: 1.5), .passthrough)
            }
        }
    }

    func testAlternateBrightnessKeyParserRecognizesDirectionReleaseAndRepeat() {
        for (keyCode, direction) in [(Int64(144), BrightnessDirection.up), (Int64(145), .down)] {
            for phase in [BrightnessKeyPhase.down, .up] {
                for repeated in [false, true] {
                    XCTAssertEqual(BrightnessKeyEvent.parseKeyboard(keyCode: keyCode, phase: phase,
                                        isRepeat: repeated, modifierBits: 0),
                                   event(direction, phase: phase, repeated: repeated))
                }
            }
        }
    }

    func testAlternateParserRejectsEveryOtherVirtualKeyWithoutRemappingFunctionKeys() {
        for keyCode in Int64(0)...Int64(UInt16.max) where keyCode != 144 && keyCode != 145 {
            for phase in [BrightnessKeyPhase.down, .up] {
                XCTAssertNil(BrightnessKeyEvent.parseKeyboard(keyCode: keyCode, phase: phase,
                                                              isRepeat: false, modifierBits: 0))
            }
        }
        for keyCode in [Int64.min, -1, 65536, Int64.max] {
            XCTAssertNil(BrightnessKeyEvent.parseKeyboard(keyCode: keyCode, phase: .down,
                                                          isRepeat: true, modifierBits: shift | option))
        }
    }

    func testAlternateKeyModifiersMatchSystemDefinedBrightnessModifiers() {
        let capsAndFunction: UInt64 = (1 << 16) | (1 << 23)
        for modifiers in [UInt64(0), capsAndFunction, shift | option, shift | option | capsAndFunction,
                          shift, control, option, command, shift | option | command] {
            XCTAssertEqual(BrightnessKeyEvent.parseKeyboard(keyCode: 144, phase: .down,
                                isRepeat: true, modifierBits: modifiers),
                           BrightnessKeyEvent.parse(subtype: 8, data1: mediaData(repeated: true),
                                                    modifierBits: modifiers))
        }
    }

    func testAlternateKeyHoldUsesUnifiedPolicyAndConsumesItsRelease() throws {
        var sequence = BrightnessKeySequence()
        let down = try XCTUnwrap(BrightnessKeyEvent.parseKeyboard(keyCode: 145, phase: .down,
                                                                 isRepeat: false, modifierBits: 0))
        let repeated = try XCTUnwrap(BrightnessKeyEvent.parseKeyboard(keyCode: 145, phase: .down,
                                                                     isRepeat: true, modifierBits: 0))
        let up = try XCTUnwrap(BrightnessKeyEvent.parseKeyboard(keyCode: 145, phase: .up,
                                                               isRepeat: false, modifierBits: 0))
        XCTAssertEqual(route(down, through: &sequence, normal: 0.02), .setNative(0.01))
        XCTAssertEqual(route(repeated, through: &sequence, normal: 0.01), .start(0.9375))
        XCTAssertEqual(route(up, through: &sequence, state: .on, factor: 0.9375, normal: 0.01), .consume)
    }

    func testNativeKeysUseOneOwnedHardwareRange() {
        XCTAssertEqual(action(event(), normal: 0.5), .setNative(0.5625))
        XCTAssertEqual(action(event(.down), normal: 0.5), .setNative(0.4375))
        XCTAssertEqual(action(event(repeated: true), normal: 0.5), .setNative(0.5625))
        XCTAssertEqual(action(event(.down, repeated: true), normal: 0.5), .setNative(0.4375))
        XCTAssertEqual(action(event(fine: true), normal: 0.5), .setNative(0.515625))
        XCTAssertEqual(action(event(.down, fine: true), normal: 0.5), .setNative(0.484375))
    }

    func testNativeRangeClampsToLitFloorAndMaximum() {
        XCTAssertEqual(action(event(.down), normal: 0.02, dimmingAvailable: true), .setNative(0.01))
        XCTAssertEqual(action(event(.down, fine: true), normal: 0.012, dimmingAvailable: true), .setNative(0.01))
        XCTAssertEqual(action(event(), normal: 0.99), .setNative(1))
        XCTAssertEqual(action(event(fine: true), normal: 0.999), .setNative(1))
    }

    func testHardwareZeroDownDoesNotRelightButUpDoes() {
        XCTAssertEqual(action(event(.down), normal: 0, dimmingAvailable: true), .consume)
        XCTAssertEqual(action(event(.down, repeated: true), normal: 0, dimmingAvailable: true), .consume)
        XCTAssertEqual(action(event(), normal: 0), .setNative(0.0625))
        XCTAssertEqual(action(event(fine: true), normal: 0), .setNative(0.015625))
    }

    func testHeldKeysStartExtraRangesAtConfirmedEndpoints() {
        for repeated in [false, true] {
            XCTAssertEqual(action(event(repeated: repeated)), .start(1.0625))
            XCTAssertEqual(action(event(repeated: repeated, fine: true)), .start(1.015625))
            XCTAssertEqual(action(event(.down, repeated: repeated), normal: 0.01,
                                  dimmingAvailable: true), .start(0.9375))
            XCTAssertEqual(action(event(.down, repeated: repeated, fine: true), normal: 0.01,
                                  dimmingAvailable: true), .start(0.984375))
        }
    }

    func testMissingExtraCapabilityStillConsumesAtNativeEndpoint() {
        XCTAssertEqual(action(event(), available: false), .consume)
        XCTAssertEqual(action(event(.down), normal: 0.01, dimmingAvailable: false), .consume)
        for ceiling in [0, 1, 1.01, Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(action(event(), ceiling: ceiling), .consume)
        }
        XCTAssertEqual(action(event(.down), ceiling: 1, normal: 0.01,
                              available: false, dimmingAvailable: true), .start(0.9375))
    }

    func testUnavailableExtraSessionStillAllowsNativeBrightness() {
        XCTAssertEqual(action(event(), state: .unavailable, normal: 0.5), .setNative(0.5625))
        XCTAssertEqual(action(event(.down), state: .unavailable, normal: 0.5), .setNative(0.4375))
        XCTAssertEqual(action(event(), state: .unavailable, normal: 1), .consume)
        XCTAssertEqual(action(event(.down), state: .unavailable, normal: 0.01,
                              dimmingAvailable: true), .consume)
    }

    func testMissingNativeControlOrInvalidReadPassesThrough() {
        for state in [BrightnessBoostState.off, .preparing, .on, .unavailable] {
            XCTAssertEqual(action(event(), state: state, nativeAvailable: false), .passthrough)
        }
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -0.01, 1.001]
        for state in [BrightnessBoostState.off, .unavailable] {
            for normal in invalid {
                XCTAssertEqual(action(event(), state: state, normal: normal), .passthrough)
                XCTAssertEqual(action(event(.down), state: state, normal: normal,
                                      dimmingAvailable: true), .passthrough)
            }
        }
    }

    func testRestorationStillConsumesKeysWhenNativeControlBecomesUnavailable() {
        for direction in [BrightnessDirection.up, .down] {
            for repeated in [false, true] {
                for fine in [false, true] {
                    XCTAssertEqual(action(event(direction, repeated: repeated, fine: fine),
                                          state: .stopping, normal: nil, nativeAvailable: false), .consume)
                }
            }
            XCTAssertEqual(action(event(direction, phase: .up), state: .stopping,
                                  normal: nil, nativeAvailable: false), .passthrough)
        }
    }

    func testFreshEndpointValidationMatchesNativePolicy() {
        XCTAssertTrue(BrightnessKeyPolicy.canStart(mode: .boost, normalBrightness: 1, available: true, ceiling: 2))
        XCTAssertFalse(BrightnessKeyPolicy.canStart(mode: .boost, normalBrightness: 0.999, available: true, ceiling: 2))
        XCTAssertTrue(BrightnessKeyPolicy.canStart(mode: .dim, normalBrightness: 0.01, available: true, ceiling: 1))
        XCTAssertFalse(BrightnessKeyPolicy.canStart(mode: .dim, normalBrightness: 0.0625, available: true, ceiling: 2))
        XCTAssertFalse(BrightnessKeyPolicy.canStart(mode: .dim, normalBrightness: 0, available: true, ceiling: 2))
    }

    func testActiveBoostAndDimmingSupportFineAndRepeatedChanges() {
        for state in [BrightnessBoostState.preparing, .on] {
            XCTAssertEqual(action(event(repeated: true), state: state, factor: 1.5), .set(1.5625))
            XCTAssertEqual(action(event(.down, repeated: true), state: state, factor: 1.5), .set(1.4375))
            XCTAssertEqual(action(event(fine: true), state: state, factor: 1.5), .set(1.515625))
            XCTAssertEqual(action(event(.down, fine: true), state: state, factor: 0.5, ceiling: 1), .set(0.484375))
            XCTAssertEqual(action(event(repeated: true), state: state, factor: 0.5, ceiling: 1), .set(0.5625))
        }
    }

    func testExtraRangeLimitsDoNotWriteRepeatedlyOrCrossIntoBlack() {
        XCTAssertEqual(action(event(), state: .on, factor: 1.98), .set(2))
        XCTAssertEqual(action(event(repeated: true), state: .on, factor: 2), .consume)
        XCTAssertEqual(action(event(.down), state: .on, factor: 0.125), .set(0.1))
        XCTAssertEqual(action(event(.down, repeated: true), state: .on, factor: 0.1), .consume)
        XCTAssertEqual(action(event(), state: .on, factor: 0.1), .set(0.1625))
        XCTAssertEqual(action(event(), state: .on, factor: 2, ceiling: 1.5), .set(1.5))
    }

    func testBothDirectionsRestoreBeforeChangingHardware() {
        for state in [BrightnessBoostState.preparing, .on] {
            XCTAssertEqual(action(event(.down), state: state, factor: 1.0625), .stop)
            XCTAssertEqual(action(event(), state: state, factor: 0.9375), .stop)
            XCTAssertEqual(action(event(.down, fine: true), state: state, factor: 1.015625), .stop)
            XCTAssertEqual(action(event(fine: true), state: state, factor: 0.984375), .stop)
        }
        for direction in [BrightnessDirection.up, .down] {
            XCTAssertEqual(action(event(direction, repeated: true), state: .stopping, normal: 0.5), .consume)
        }
    }

    func testInvalidActiveValuesRequestRestoration() {
        for invalid in [Double.nan, .infinity, -.infinity, 0, -0.1] {
            XCTAssertEqual(action(event(), state: .on, factor: invalid, mode: .dim), .stop)
        }
        for invalid in [Double.nan, .infinity, -.infinity, 0, 1] {
            XCTAssertEqual(action(event(.down), state: .on, factor: 1.5, ceiling: invalid), .stop)
        }
        XCTAssertEqual(action(event(), state: .on, factor: 1.2, mode: .dim), .stop)
        XCTAssertEqual(action(event(.down), state: .on, factor: 0.8, mode: .boost), .stop)
    }

    func testKeyUpDoesNotChooseAnAdjustment() {
        for state in [BrightnessBoostState.off, .preparing, .on, .stopping, .unavailable] {
            for direction in [BrightnessDirection.up, .down] {
                XCTAssertEqual(action(event(direction, phase: .up), state: state), .passthrough)
            }
        }
    }

    func testNativeAndExtraRangeKeysShareOneConsumedRelease() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.9375), .setNative(1))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 1), .start(1.0625))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.0625), .set(1.125))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.125), .consume)
        XCTAssertEqual(route(event(phase: .up), through: &sequence), .passthrough)
    }

    func testUnknownNativeHoldKeepsItsReleaseAfterCapture() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 0.5), .setNative(0.5625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, normal: 0.5625), .passthrough)
    }

    func testFallbackNativePressKeepsItsReleaseAfterRecovery() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.5, nativeAvailable: false), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 0.5625), .setNative(0.625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, normal: 0.625), .passthrough)
    }

    func testNativeCapabilityFailureMidHoldFallsBackAndReleasesToMacOS() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.5), .setNative(0.5625))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: nil, nativeAvailable: false), .passthrough)
        XCTAssertEqual(route(event(phase: .up), through: &sequence), .passthrough)
    }

    func testUnsupportedModifiersPassThroughForFreshNativeSequence() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down, unsupported: true), through: &sequence, normal: 0.5), .passthrough)
        XCTAssertEqual(route(event(.down, repeated: true, unsupported: true), through: &sequence, normal: 0.5), .passthrough)
        XCTAssertEqual(route(event(.down, phase: .up, unsupported: true), through: &sequence, normal: 0.5), .passthrough)
    }

    func testModifierChangeDoesNotLeakAnOwnedSequenceToNative() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.5), .setNative(0.4375))
        XCTAssertEqual(route(event(.down, repeated: true, unsupported: true), through: &sequence, normal: 0.4375), .consume)
        XCTAssertEqual(route(event(.down, phase: .up, unsupported: true), through: &sequence), .consume)
    }

    func testReleaseSuppressesQueuedRepeatsUntilAFreshPress() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.5), .setNative(0.4375))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence), .consume)
        for _ in 0..<50 {
            XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.4375), .consume)
        }
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.4375), .setNative(0.375))
    }

    func testCancellationSuppressesOwnedHoldAndPreservesReleaseOwnership() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.5), .setNative(0.5625))
        sequence.reset()
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 0.5625), .consume)
        XCTAssertEqual(route(event(phase: .up), through: &sequence), .consume)
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.5625), .setNative(0.625))
    }

    func testCancellationStillReleasesFallbackNativePress() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, nativeAvailable: false), .passthrough)
        sequence.reset()
        XCTAssertEqual(route(event(repeated: true), through: &sequence), .consume)
        XCTAssertEqual(route(event(phase: .up), through: &sequence), .passthrough)
    }

    func testOppositeReleaseDoesNotCancelHeldDirection() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.5), .setNative(0.5625))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 0.5625), .setNative(0.625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence), .consume)
    }

    func testRestoredBoostDownContinuesNativelyWithoutAnotherPress() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, state: .on, factor: 1.0625), .stop)
        for _ in 0..<25 {
            XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .stopping), .consume)
        }
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 1), .setNative(0.9375))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence), .consume)
    }

    func testRestoredDimmingUpContinuesNativelyWithoutAnotherPress() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 0.9375, normal: 0.01), .stop)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .stopping, normal: 0.01), .consume)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 0.01), .setNative(0.0725))
        XCTAssertEqual(route(event(phase: .up), through: &sequence), .consume)
    }

    func testRapidReverseUsesLatestProjectedNativeValue() {
        var sequence = BrightnessKeySequence()
        var normal = 0.5
        for _ in 0..<100 {
            let up = route(event(), through: &sequence, normal: normal)
            XCTAssertEqual(up, .setNative(0.5625))
            if case .setNative(let value) = up { normal = value }
            let down = route(event(.down), through: &sequence, normal: normal)
            XCTAssertEqual(down, .setNative(0.5))
            if case .setNative(let value) = down { normal = value }
        }
        XCTAssertEqual(normal, 0.5)
    }

    func testFullHeldRangeRoundTripAndFineStress() {
        for fine in [false, true] {
            var sequence = BrightnessKeySequence()
            var state = BrightnessBoostState.off
            var normal = 0.5
            var factor = 1.0
            var mode = BrightnessAdjustmentMode.boost
            var visitedNative = false, visitedBoost = false, visitedDim = false
            for direction in [BrightnessDirection.up, .down, .up] {
                for index in 0..<300 {
                    let before = logicalLevel(normal: normal, factor: factor, state: state)
                    let result = route(event(direction, repeated: index > 0, fine: fine), through: &sequence,
                                       state: state, factor: factor, normal: normal, mode: mode)
                    switch result {
                    case .setNative(let value):
                        XCTAssertTrue((0.01...1).contains(value))
                        normal = value; visitedNative = true
                    case .start(let value):
                        factor = value; mode = value < 1 ? .dim : .boost; state = .preparing
                        visitedDim = visitedDim || value < 1; visitedBoost = visitedBoost || value > 1
                    case .set(let value):
                        XCTAssertTrue((0.1...2).contains(value))
                        factor = value; state = .on
                    case .stop:
                        state = .stopping; factor = 1
                    case .consume:
                        if state == .stopping { state = .off }
                    case .passthrough:
                        XCTFail("Supported full-range keys must stay owned")
                    }
                    let after = logicalLevel(normal: normal, factor: factor, state: state)
                    if direction == .up { XCTAssertGreaterThanOrEqual(after + 0.000001, before) }
                    else { XCTAssertLessThanOrEqual(after - 0.000001, before) }
                }
                XCTAssertEqual(route(event(direction, phase: .up), through: &sequence,
                                     state: state, factor: factor, normal: normal, mode: mode), .consume)
            }
            XCTAssertTrue(visitedNative && visitedBoost && visitedDim)
            XCTAssertEqual(normal, 1)
            XCTAssertEqual(factor, 2)
        }
    }

    private func logicalLevel(normal: Double, factor: Double, state: BrightnessBoostState) -> Double {
        if state == .on || state == .preparing {
            if factor < 1 { return factor }
            return 2 + factor - 1
        }
        return 1 + (normal - 0.01) / 0.99
    }
}
