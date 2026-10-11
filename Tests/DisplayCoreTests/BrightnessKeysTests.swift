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
        mode: BrightnessAdjustmentMode? = nil
    ) -> BrightnessKeyAction {
        BrightnessKeyPolicy.action(event: event, state: state, factor: factor, ceiling: ceiling,
                                   normalBrightness: normal, available: available,
                                   dimmingAvailable: dimmingAvailable, mode: mode)
    }

    private func route(
        _ event: BrightnessKeyEvent,
        through sequence: inout BrightnessKeySequence,
        state: BrightnessBoostState = .off,
        factor: Double = 1,
        normal: Double? = 1,
        dimmingAvailable: Bool = true,
        mode: BrightnessAdjustmentMode? = nil,
        nativeDownReadPending: Bool = false
    ) -> BrightnessKeyAction {
        sequence.route(event: event, state: state, factor: factor, ceiling: 2,
                       normalBrightness: normal, available: true,
                       dimmingAvailable: dimmingAvailable, mode: mode,
                       nativeDownReadPending: nativeDownReadPending)
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

    func testNormalRangeRemainsUnderSystemControl() {
        for brightness in [0.0, 0.5, 0.9989] {
            XCTAssertEqual(action(event(), normal: brightness), .passthrough)
            XCTAssertEqual(action(event(.down), normal: brightness), .passthrough)
        }
        XCTAssertEqual(action(event(.down)), .passthrough)
    }

    func testUnconfirmedOrNonfiniteHardwareBrightnessCannotStartBoost() {
        let brightnesses: [Double?] = [nil, .nan, .infinity, -.infinity, 1.2]
        for brightness in brightnesses {
            XCTAssertEqual(action(event(), normal: brightness), .passthrough)
        }
    }

    func testFreshUpAtNormalMaximumStartsAtFirstStep() {
        XCTAssertEqual(action(event()), .start(1.0625))
        XCTAssertEqual(action(event(), normal: 0.999), .start(1.0625))
        XCTAssertEqual(action(event(), normal: 1.0001), .start(1.0625))
        XCTAssertEqual(action(event(fine: true)), .start(1.015625))
        XCTAssertEqual(action(event(), ceiling: 1.02), .start(1.02))
    }

    func testHoldingUpContinuesFromNormalRangeIntoBoost() {
        XCTAssertEqual(action(event(repeated: true)), .start(1.0625))
        XCTAssertEqual(action(event(repeated: true, fine: true)), .start(1.015625))
        XCTAssertEqual(action(event()), .start(1.0625))
    }

    func testUnavailableOrMissingHeadroomCannotStartBoost() {
        XCTAssertEqual(action(event(), available: false), .passthrough)
        XCTAssertEqual(action(event(), state: .unavailable), .passthrough)
        for ceiling in [-1.0, 1, 1.01, .nan, .infinity, -.infinity] {
            XCTAssertEqual(action(event(), ceiling: ceiling), .passthrough)
        }
    }

    func testBoostSupportsHeldKeysAndFineAdjustmentWhilePreparingOrOn() {
        for state in [BrightnessBoostState.preparing, .on] {
            XCTAssertEqual(action(event(repeated: true), state: state, factor: 1.5), .set(1.5625))
            XCTAssertEqual(action(event(.down, repeated: true), state: state, factor: 1.5), .set(1.4375))
            XCTAssertEqual(action(event(fine: true), state: state, factor: 1.5), .set(1.515625))
            XCTAssertEqual(action(event(.down, fine: true), state: state, factor: 1.5), .set(1.484375))
        }
    }

    func testBoostStopsBeforeBrightnessDownReturnsToTheSystem() {
        for state in [BrightnessBoostState.preparing, .on] {
            XCTAssertEqual(action(event(.down), state: state, factor: 1.0625), .stop)
            XCTAssertEqual(action(event(.down), state: state, factor: 1.02), .stop)
            XCTAssertEqual(action(event(.down, fine: true), state: state, factor: 1.015625), .stop)
            XCTAssertEqual(action(event(.down), state: state, factor: 1), .stop)
        }
        XCTAssertEqual(action(event(.down), state: .stopping), .consume)
        XCTAssertEqual(action(event(.down), state: .off), .passthrough)
    }

    func testCeilingChangesClampBoostAndHoldingAtMaximumDoesNotWriteAgain() {
        XCTAssertEqual(action(event(), state: .on, factor: 1.98), .set(2))
        XCTAssertEqual(action(event(repeated: true), state: .on, factor: 2), .consume)
        XCTAssertEqual(action(event(), state: .on, factor: 2, ceiling: 1.5), .set(1.5))
        XCTAssertEqual(action(event(.down), state: .on, factor: 2, ceiling: 1.5), .set(1.4375))
        XCTAssertEqual(action(event(.down), state: .on, factor: 0.5, mode: .boost), .stop)
    }

    func testInvalidActiveValuesRequestRestorationInsteadOfSendingInvalidFactors() {
        for state in [BrightnessBoostState.preparing, .on] {
            for invalid in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(action(event(), state: state, factor: invalid), .stop)
                XCTAssertEqual(action(event(.down), state: state, ceiling: invalid), .stop)
            }
            for ceiling in [0.0, 1, 1.01] {
                XCTAssertEqual(action(event(.down), state: state, factor: 1.5, ceiling: ceiling), .stop)
            }
        }
    }

    func testKeyUpLeavesPairHandlingToTheController() {
        for state in [BrightnessBoostState.off, .preparing, .on, .stopping, .unavailable] {
            for direction in [BrightnessDirection.up, .down] {
                XCTAssertEqual(action(event(direction, phase: .up), state: state, factor: 1.5), .passthrough)
            }
        }
    }

    func testRestorationConsumesBrightnessKeysUntilComplete() {
        XCTAssertEqual(action(event(), state: .stopping), .consume)
        XCTAssertEqual(action(event(.down, repeated: true), state: .stopping), .consume)
    }

    func testNativeHeldUpEntersBoostAndKeepsItsNativeRelease() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.9), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence), .start(1.0625))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.5), .set(1.5625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence), .passthrough)
        XCTAssertEqual(route(event(), through: &sequence), .start(1.0625))
    }

    func testOwnedBoostRepeatsAdjustAndReleaseIsConsumedOnce() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 1.5), .set(1.5625))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.5625), .set(1.625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.625), .consume)
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.625), .passthrough)
    }

    func testHeldDownWaitsForRestorationThenReturnsToNativeWithoutReplay() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, state: .on, factor: 1.0625), .stop)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .stopping), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .off), .passthrough)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.9), .passthrough)
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence), .passthrough)
        XCTAssertEqual(route(event(.down), through: &sequence), .passthrough)
    }

    func testReleaseBeforeHandoffRemainsConsumedAfterRestoration() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, state: .on, factor: 1.0625), .stop)
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, state: .off), .consume)
        XCTAssertEqual(route(event(.down), through: &sequence, state: .off), .passthrough)
    }

    func testResetCanResumeExistingNativeHoldWithoutStealingItsRelease() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence), .start(1.0625))
        sequence.reset()
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.5), .set(1.5625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.5), .passthrough)
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 1.5), .set(1.5625))
    }

    func testUnsupportedFreshSequencePassesThroughButOwnedSequenceStaysPaired() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(unsupported: true), through: &sequence, state: .on, factor: 1.5), .passthrough)
        XCTAssertEqual(route(event(repeated: true, unsupported: true), through: &sequence, state: .on, factor: 1.5), .passthrough)
        XCTAssertEqual(route(event(phase: .up, unsupported: true), through: &sequence, state: .on, factor: 1.5), .passthrough)
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 1.5), .set(1.5625))
        XCTAssertEqual(route(event(repeated: true, unsupported: true), through: &sequence, state: .on, factor: 1.5625), .consume)
        XCTAssertEqual(route(event(phase: .up, unsupported: true), through: &sequence, state: .on, factor: 1.5625), .consume)
    }

    func testUnsupportedModifierDoesNotTriggerNativeActionDuringDownHandoff() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, state: .on, factor: 1.0625), .stop)
        XCTAssertEqual(route(event(.down, repeated: true, unsupported: true), through: &sequence, state: .off), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .off), .passthrough)
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence), .passthrough)
    }

    func testUpRemainsConsumedIfBoostStopsDuringTheHeldSequence() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 2), .consume)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .stopping), .consume)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .off), .consume)
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .off), .consume)
        XCTAssertEqual(route(event(), through: &sequence), .start(1.0625))
    }

    func testOppositeKeyReleaseDoesNotClearOwnedSequence() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 1.5), .set(1.5625))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, state: .on, factor: 1.5625), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.5625), .set(1.625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.625), .consume)
    }

    func testFreshDownAtLitNativeStepStartsDimmingWithoutEDRHeadroom() {
        for minimum in [0.01, 0.015625, 0.0625, 0.0635] {
            XCTAssertEqual(action(event(.down), ceiling: 1, normal: minimum,
                                  available: false, dimmingAvailable: true), .start(0.9375))
        }
        XCTAssertEqual(action(event(.down, fine: true), ceiling: 1, normal: 0.0625,
                              available: false, dimmingAvailable: true), .start(0.984375))
    }

    func testDimmingRequiresConfirmedMinimumAndItsOwnAvailability() {
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -0.0001, 0, 0.0636, 0.5, 1, 1.2]
        for brightness in invalid {
            XCTAssertEqual(action(event(.down), normal: brightness, dimmingAvailable: true), .passthrough)
        }
        XCTAssertEqual(action(event(.down), normal: 0.0625, dimmingAvailable: false), .passthrough)
        XCTAssertEqual(action(event(.down), state: .unavailable, normal: 0.0625, dimmingAvailable: true), .passthrough)
        XCTAssertEqual(action(event(.down, repeated: true), normal: 0.0625, dimmingAvailable: true), .start(0.9375))
        XCTAssertEqual(action(event(.down, unsupported: true), normal: 0.0625, dimmingAvailable: true), .passthrough)
    }

    func testNormalRangeRemainsNativeWithBothExtraRangesAvailable() {
        for brightness in [0.0636, 0.5, 0.9989] {
            for direction in [BrightnessDirection.up, .down] {
                XCTAssertEqual(action(event(direction), normal: brightness, dimmingAvailable: true), .passthrough)
            }
        }
        XCTAssertEqual(action(event(), normal: 0.0625, dimmingAvailable: true), .passthrough)
        XCTAssertEqual(action(event(.down), normal: 1, dimmingAvailable: true), .passthrough)
    }

    func testDimmingSupportsRepeatsAndFineAdjustmentWhilePreparingOrOn() {
        for state in [BrightnessBoostState.preparing, .on] {
            XCTAssertEqual(action(event(.down, repeated: true), state: state, factor: 0.5, ceiling: 1), .set(0.4375))
            XCTAssertEqual(action(event(repeated: true), state: state, factor: 0.5, ceiling: 1), .set(0.5625))
            XCTAssertEqual(action(event(.down, fine: true), state: state, factor: 0.5, ceiling: 1), .set(0.484375))
            XCTAssertEqual(action(event(fine: true), state: state, factor: 0.5, ceiling: 1), .set(0.515625))
        }
    }

    func testDimmingClampsAtVisibleFloorAndDoesNotRepeatedlyWriteIt() {
        XCTAssertEqual(action(event(.down), state: .on, factor: 0.125, ceiling: 1), .set(0.1))
        XCTAssertEqual(action(event(.down, repeated: true), state: .on, factor: 0.1, ceiling: 1), .consume)
        XCTAssertEqual(action(event(), state: .on, factor: 0.1, ceiling: 1), .set(0.1625))
        XCTAssertEqual(action(event(.down), state: .on, factor: 0.05, ceiling: 1), .set(0.1))
        for invalid in [0.0, -0.1, Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(action(event(.down), state: .on, factor: invalid, ceiling: 1, mode: .dim), .stop)
        }
    }

    func testDimmingRestoresBeforeUpCanRaiseHardwareBrightness() {
        for state in [BrightnessBoostState.preparing, .on] {
            XCTAssertEqual(action(event(), state: state, factor: 0.9375, ceiling: 1), .stop)
            XCTAssertEqual(action(event(), state: state, factor: 0.98, ceiling: 1), .stop)
            XCTAssertEqual(action(event(fine: true), state: state, factor: 0.984375, ceiling: 1), .stop)
            XCTAssertEqual(action(event(), state: state, factor: 1, ceiling: 1, mode: .dim), .stop)
        }
        XCTAssertEqual(action(event(), state: .stopping, factor: 1, ceiling: 1, mode: .dim), .consume)
    }

    func testExplicitModePreventsCrossingBetweenDimmingAndBoostWithoutRestoration() {
        XCTAssertEqual(action(event(), state: .on, factor: 1.2, mode: .dim), .stop)
        XCTAssertEqual(action(event(.down), state: .on, factor: 0.8, mode: .boost), .stop)
        XCTAssertEqual(action(event(.down), state: .on, factor: 1, ceiling: 1, mode: .dim), .set(0.9375))
        XCTAssertEqual(action(event(.down), state: .on, factor: 1, mode: .boost), .stop)
    }

    func testFreshReadBeforeStartUsesTheSameEndpointRules() {
        XCTAssertTrue(BrightnessKeyPolicy.canStart(mode: .dim, normalBrightness: 0.0625, available: true, ceiling: 1))
        XCTAssertFalse(BrightnessKeyPolicy.canStart(mode: .dim, normalBrightness: 0.08, available: true, ceiling: 2))
        XCTAssertTrue(BrightnessKeyPolicy.canStart(mode: .boost, normalBrightness: 1, available: true, ceiling: 2))
        XCTAssertFalse(BrightnessKeyPolicy.canStart(mode: .boost, normalBrightness: 0.98, available: true, ceiling: 2))
    }

    func testNativeHeldDownEntersDimmingAndKeepsItsNativeRelease() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.1), .passthrough)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.0625), .start(0.9375))
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .on, factor: 0.5, normal: 0.0625), .set(0.4375))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, normal: 0.0625), .passthrough)
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.0625), .start(0.9375))
    }

    func testOwnedDimmingRepeatsAdjustAndReleaseIsConsumedOnce() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.0625), .start(0.9375))
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .preparing, factor: 0.9375, normal: 0.0625), .set(0.875))
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .on, factor: 0.875, normal: 0.0625), .set(0.8125))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, state: .on, factor: 0.8125, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, state: .on, factor: 0.8125, normal: 0.0625), .passthrough)
    }

    func testHeldUpWaitsForDimmingRestorationThenReturnsToNativeWithoutReplay() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 0.9375, normal: 0.0625), .stop)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .stopping, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .off, normal: 0.0625), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 0.1), .passthrough)
        XCTAssertEqual(route(event(phase: .up), through: &sequence, normal: 0.1), .passthrough)
    }

    func testDimmingUpReleaseBeforeHandoffRemainsConsumedAfterRestoration() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 0.9375, normal: 0.0625), .stop)
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .off, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(), through: &sequence, state: .off, normal: 0.0625), .passthrough)
    }

    func testHeldDownStaysConsumedIfDimmingStopsUnexpectedly() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, state: .on, factor: 0.1, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .stopping, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .off, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, state: .off, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(.down), through: &sequence, state: .off, normal: 0.0625), .start(0.9375))
    }

    func testUnsupportedModifierDoesNotTriggerNativeActionDuringDimmingHandoff() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 0.9375, normal: 0.0625), .stop)
        XCTAssertEqual(route(event(repeated: true, unsupported: true), through: &sequence, state: .off, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .off, normal: 0.0625), .passthrough)
        XCTAssertEqual(route(event(phase: .up), through: &sequence, normal: 0.0625), .passthrough)
    }


    func testHardwareZeroCannotStartDimmingBecauseTheBacklightIsOff() {
        XCTAssertEqual(action(event(.down), normal: 0, dimmingAvailable: true), .passthrough)
        XCTAssertEqual(action(event(), normal: 0, dimmingAvailable: true), .passthrough)
    }

    func testNativeDownRepeatWaitsForFreshReadWithoutStealingItsRelease() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.125), .passthrough)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.125,
                             nativeDownReadPending: true), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.0625), .start(0.9375))
        // Once captured, a failed start cannot forward more Down repeats.
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: nil), .consume)
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, normal: 0.0625), .passthrough)
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.0625), .start(0.9375))
    }

    func testFreshDownDuringReadSettlingKeepsItsOwnPairConsumed() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.125,
                             nativeDownReadPending: true), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.0625), .start(0.9375))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.0625), .start(0.9375))
    }


    func testOneHeldDownTraversesBoostNativeRangeAndDimming() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, state: .on, factor: 1.125), .set(1.0625))
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .on, factor: 1.0625), .stop)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .stopping), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 1), .passthrough)
        for normal in stride(from: 0.9375, through: 0.125, by: -0.0625) {
            XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: normal), .passthrough)
        }
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.125,
                             nativeDownReadPending: true), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, normal: 0.0625), .start(0.9375))
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .preparing,
                             factor: 0.9375, normal: 0.0625), .set(0.875))
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .on,
                             factor: 0.875, normal: 0.0625), .set(0.8125))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, state: .on,
                             factor: 0.8125, normal: 0.0625), .passthrough)
    }

    func testOneHeldUpTraversesDimmingNativeRangeAndBoost() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 0.875, normal: 0.0625), .set(0.9375))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 0.9375, normal: 0.0625), .stop)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .stopping, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 0.0625), .passthrough)
        for normal in stride(from: 0.125, through: 0.9375, by: 0.0625) {
            XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: normal), .passthrough)
        }
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 1), .start(1.0625))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .preparing, factor: 1.0625), .set(1.125))
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.125), .set(1.1875))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.1875), .passthrough)
    }

    func testNativeFineHeldDownContinuesAcrossLitBoundary() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down, fine: true), through: &sequence, normal: 0.078125), .passthrough)
        XCTAssertEqual(route(event(.down, repeated: true, fine: true), through: &sequence, normal: 0.0625), .start(0.984375))
        XCTAssertEqual(route(event(.down, repeated: true, fine: true), through: &sequence,
                             state: .on, factor: 0.984375, normal: 0.0625), .set(0.96875))
        XCTAssertEqual(route(event(.down, phase: .up, fine: true), through: &sequence,
                             state: .on, factor: 0.96875, normal: 0.0625), .passthrough)
    }

    func testReleaseEndsCapturedNativeHoldAndLateRepeatCannotRestartIt() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.9375), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, normal: 1), .start(1.0625))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.0625), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.0625), .passthrough)
        XCTAssertEqual(route(event(), through: &sequence, state: .on, factor: 1.0625), .set(1.125))
        XCTAssertEqual(route(event(phase: .up), through: &sequence, state: .on, factor: 1.125), .consume)
    }

    func testHeadroomOnlyHoldReleaseIsConsumedAndEndsAdjustment() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(.down), through: &sequence, normal: 0.0625), .start(0.9375))
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .on,
                             factor: 0.9375, normal: 0.0625), .set(0.875))
        XCTAssertEqual(route(event(.down, phase: .up), through: &sequence, state: .on,
                             factor: 0.875, normal: 0.0625), .consume)
        XCTAssertEqual(route(event(.down, repeated: true), through: &sequence, state: .on,
                             factor: 0.875, normal: 0.0625), .passthrough)
    }

}
