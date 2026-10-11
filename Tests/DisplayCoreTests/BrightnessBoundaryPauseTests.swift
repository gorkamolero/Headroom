import XCTest
@testable import DisplayCore

final class BrightnessBoundaryPauseTests: XCTestCase {
    private func event(_ direction: BrightnessDirection = .up,
                       phase: BrightnessKeyPhase = .down,
                       repeated: Bool = true,
                       unsupported: Bool = false) -> BrightnessKeyEvent {
        .init(direction: direction, phase: phase, isRepeat: repeated,
              hasUnsupportedModifiers: unsupported)
    }

    func testUnarmedKeysAreNeverPaused() {
        var pause = BrightnessBoundaryPause()
        for direction in [BrightnessDirection.up, .down] {
            XCTAssertFalse(pause.shouldPause(event: event(direction), now: 0))
        }
        pause.reachedBoundary(now: 10)
        XCTAssertNil(pause.armedDirection)
        XCTAssertFalse(pause.shouldPause(event: event(), now: 10.1))
    }

    func testBothDirectionsWaitForRealArrivalBeforeStartingDeadline() {
        for direction in [BrightnessDirection.up, .down] {
            var pause = BrightnessBoundaryPause()
            pause.begin(direction: direction)
            XCTAssertTrue(pause.isWaiting)
            XCTAssertEqual(pause.armedDirection, direction)
            // A slow write or restoration does not consume the 350ms detent.
            XCTAssertTrue(pause.shouldPause(event: event(direction), now: 1))
            XCTAssertTrue(pause.shouldPause(event: event(direction), now: 20))
            pause.reachedBoundary(now: 20)
            XCTAssertFalse(pause.isWaiting)
            XCTAssertTrue(pause.shouldPause(event: event(direction), now: 20.349))
            XCTAssertFalse(pause.shouldPause(event: event(direction), now: 20 + BrightnessBoundaryPause.duration))
            XCTAssertNil(pause.armedDirection)
        }
    }

    func testRepeatedKeysAndDuplicateConfirmationNeverExtendDeadline() {
        var pause = BrightnessBoundaryPause()
        pause.begin(direction: .down)
        pause.reachedBoundary(now: 10)
        for index in 0..<30 {
            let now = 10 + Double(index) / 100
            XCTAssertTrue(pause.shouldPause(event: event(.down), now: now))
            pause.begin(direction: .down)
            pause.reachedBoundary(now: now)
        }
        XCTAssertFalse(pause.shouldPause(event: event(.down), now: 10 + BrightnessBoundaryPause.duration))
    }

    func testReleaseBeforeConfirmationCancelsAndLateConfirmationDoesNotRearm() {
        var pause = BrightnessBoundaryPause()
        pause.begin(direction: .up)
        XCTAssertFalse(pause.shouldPause(event: event(phase: .up), now: 1))
        pause.reachedBoundary(now: 2)
        XCTAssertNil(pause.armedDirection)
        XCTAssertFalse(pause.shouldPause(event: event(), now: 2.1))
    }

    func testReleaseDuringPauseMakesRepressImmediatelyResponsive() {
        var pause = BrightnessBoundaryPause()
        pause.begin(direction: .down)
        pause.reachedBoundary(now: 1)
        XCTAssertFalse(pause.shouldPause(event: event(.down, phase: .up), now: 1.05))
        XCTAssertFalse(pause.shouldPause(event: event(.down, repeated: false), now: 1.06))
        XCTAssertFalse(pause.shouldPause(event: event(.down), now: 1.07))
    }

    func testFreshPressClearsWaitingAndConfirmedPause() {
        for confirmed in [false, true] {
            var pause = BrightnessBoundaryPause()
            pause.begin(direction: .up)
            if confirmed { pause.reachedBoundary(now: 1) }
            XCTAssertFalse(pause.shouldPause(event: event(repeated: false), now: 1.1))
            pause.reachedBoundary(now: 1.2)
            XCTAssertFalse(pause.shouldPause(event: event(), now: 1.21))
        }
    }

    func testReversingDirectionClearsWaitingAndConfirmedPause() {
        for direction in [BrightnessDirection.up, .down] {
            for confirmed in [false, true] {
                var pause = BrightnessBoundaryPause()
                pause.begin(direction: direction)
                if confirmed { pause.reachedBoundary(now: 1) }
                let reverse: BrightnessDirection = direction == .up ? .down : .up
                XCTAssertFalse(pause.shouldPause(event: event(reverse), now: 1.1))
                pause.reachedBoundary(now: 1.2)
                XCTAssertFalse(pause.shouldPause(event: event(direction), now: 1.21))
            }
        }
    }

    func testResetCancelsWaitingAndConfirmedPause() {
        for confirmed in [false, true] {
            var pause = BrightnessBoundaryPause()
            pause.begin(direction: .up)
            if confirmed { pause.reachedBoundary(now: 1) }
            pause.reset()
            pause.reachedBoundary(now: 1.1)
            XCTAssertFalse(pause.shouldPause(event: event(), now: 1.2))
            XCTAssertNil(pause.armedDirection)
        }
    }

    func testUnsupportedKeyDownBypassesWithoutExtendingOrClearingBoundary() {
        var pause = BrightnessBoundaryPause()
        pause.begin(direction: .up)
        XCTAssertFalse(pause.shouldPause(event: event(.down, repeated: false, unsupported: true), now: 0))
        XCTAssertTrue(pause.isWaiting)
        pause.reachedBoundary(now: 1)
        XCTAssertFalse(pause.shouldPause(event: event(unsupported: true), now: 1.1))
        XCTAssertTrue(pause.shouldPause(event: event(), now: 1.2))
        XCTAssertFalse(pause.shouldPause(event: event(), now: 1 + BrightnessBoundaryPause.duration))
    }

    func testKeyUpWithUnsupportedModifiersStillEndsHold() {
        var pause = BrightnessBoundaryPause()
        pause.begin(direction: .up)
        XCTAssertFalse(pause.shouldPause(event: event(phase: .up, unsupported: true), now: 0))
        pause.reachedBoundary(now: 1)
        XCTAssertFalse(pause.shouldPause(event: event(), now: 1.1))
    }

    func testInvalidOrBackwardClockCannotLeaveAnIndefinitePause() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var pause = BrightnessBoundaryPause()
            pause.begin(direction: .up)
            pause.reachedBoundary(now: invalid)
            XCTAssertNil(pause.armedDirection)
            pause.begin(direction: .up)
            XCTAssertFalse(pause.shouldPause(event: event(), now: invalid))
            XCTAssertNil(pause.armedDirection)
        }
        var pause = BrightnessBoundaryPause()
        pause.begin(direction: .up)
        pause.reachedBoundary(now: 10)
        XCTAssertFalse(pause.shouldPause(event: event(), now: 9))
        XCTAssertNil(pause.armedDirection)
    }

    func testNewBoundaryCanArmAfterPreviousPauseExpired() {
        var pause = BrightnessBoundaryPause()
        pause.begin(direction: .up)
        pause.reachedBoundary(now: 1)
        XCTAssertFalse(pause.shouldPause(event: event(), now: 2))
        pause.begin(direction: .down)
        XCTAssertTrue(pause.isWaiting)
        pause.reachedBoundary(now: 3)
        XCTAssertTrue(pause.shouldPause(event: event(.down), now: 3.1))
    }
}
