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
        available: Bool = true
    ) -> BrightnessKeyAction {
        BrightnessKeyPolicy.action(event: event, state: state, factor: factor, ceiling: ceiling,
                                   normalBrightness: normal, available: available)
    }

    private func route(
        _ event: BrightnessKeyEvent,
        through sequence: inout BrightnessKeySequence,
        state: BrightnessBoostState = .off,
        factor: Double = 1,
        normal: Double? = 1
    ) -> BrightnessKeyAction {
        sequence.route(event: event, state: state, factor: factor, ceiling: 2,
                       normalBrightness: normal, available: true)
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

    func testHoldingUpDoesNotCrossFromNormalRangeIntoBoost() {
        XCTAssertEqual(action(event(repeated: true)), .passthrough)
        XCTAssertEqual(action(event(repeated: true, fine: true)), .passthrough)
        // A subsequent fresh press may enter boost without lifting any cap.
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
        XCTAssertEqual(action(event(.down), state: .on, factor: 0.5), .stop)
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

    func testNativeHeldUpStaysNativeUntilReleaseAndNewPressAtMaximum() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence, normal: 0.9), .passthrough)
        XCTAssertEqual(route(event(repeated: true), through: &sequence), .passthrough)
        // Enabling boost from the menu must not steal a key already held down.
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.5), .passthrough)
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

    func testResetForgetsInterruptedSequencesWithoutReplayingOrStealingRepeats() {
        var sequence = BrightnessKeySequence()
        XCTAssertEqual(route(event(), through: &sequence), .start(1.0625))
        sequence.reset()
        XCTAssertEqual(route(event(repeated: true), through: &sequence, state: .on, factor: 1.5), .passthrough)
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
}
