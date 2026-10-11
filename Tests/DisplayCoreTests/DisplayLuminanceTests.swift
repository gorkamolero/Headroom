import XCTest
@testable import DisplayCore

final class DisplayLuminanceTests: XCTestCase {
    func testNativeReferenceUsesLinearBrightnessWithoutGammaConversion() throws {
        let native = DisplayLuminance(referenceNits: 0.667 * 600, appliedFactor: 1)
        XCTAssertEqual(try XCTUnwrap(native.nits), 400.2, accuracy: 0.000001)
        XCTAssertEqual(native.text, "≈400 nits")
        XCTAssertTrue(native.explanation.contains("Not a physical measurement"))
    }

    func testDimmingUsesSRGBResponseRatherThanLinearTableMultiplier() throws {
        let dimmed = DisplayLuminance(referenceNits: 400.2, appliedFactor: 0.5)
        // Published sRGB inverse transfer at encoded 0.5 is 0.21404114048223255.
        XCTAssertEqual(try XCTUnwrap(dimmed.nits), 85.65926412098948, accuracy: 0.000001)
        XCTAssertNotEqual(dimmed.nits, 200.1)
        XCTAssertTrue(dimmed.explanation.contains("assumed sRGB"))
    }

    func testLowSRGBValuesUseTheLinearToe() throws {
        let dimmed = DisplayLuminance(referenceNits: 600, appliedFactor: 0.02)
        XCTAssertEqual(try XCTUnwrap(dimmed.nits), 600 * 0.02 / 12.92, accuracy: 0.000001)
    }

    func testDimmingIsMonotonicAndNeverExceedsTheNativeReference() throws {
        var previous = 0.0
        for step in 0...100 {
            let estimate = DisplayLuminance(referenceNits: 400.2, appliedFactor: Double(step) / 100)
            let current = try XCTUnwrap(estimate.nits)
            XCTAssertGreaterThanOrEqual(current, previous)
            XCTAssertLessThanOrEqual(current, 400.2)
            previous = current
        }
    }

    func testZeroNativeOrZeroScaleIsZero() {
        for value in [DisplayLuminance(referenceNits: 0, appliedFactor: 1),
                      DisplayLuminance(referenceNits: 0, appliedFactor: 0.5),
                      DisplayLuminance(referenceNits: 400.2, appliedFactor: 0)] {
            XCTAssertEqual(value.nits, 0)
            XCTAssertEqual(value.text, "≈0 nits")
        }
    }

    func testMissingAndInvalidReferencesAreUnavailableEvenWhenDimmedToZero() {
        for reference: Double? in [nil, -.infinity, .infinity, .nan, -1] {
            for factor in [0.0, 0.5, 1] {
                let value = DisplayLuminance(referenceNits: reference, appliedFactor: factor)
                XCTAssertNil(value.nits)
                XCTAssertNil(value.referenceNits)
                XCTAssertEqual(value.text, "— nits")
            }
        }
    }

    func testInvalidAppliedFactorsDoNotInventAnEstimate() {
        for factor: Double in [-1, -.infinity, .infinity, .nan] {
            XCTAssertNil(DisplayLuminance(referenceNits: 400.2, appliedFactor: factor).nits)
        }
    }

    func testBoostWithoutContextDoesNotInventAnEstimate() {
        for factor in [0.5, 1, 1.5, 2] {
            let value = DisplayLuminance(referenceNits: 400.2, appliedFactor: factor, boostActive: true)
            XCTAssertNil(value.nits)
            XCTAssertEqual(value.referenceNits, 400.2)
            XCTAssertEqual(value.text, "— nits")
        }
        XCTAssertNil(DisplayLuminance(referenceNits: 400.2, appliedFactor: 1.1).nits)
    }

    func testBoostCapacityNeverMasqueradesAsCurrentLuminance() throws {
        let context = DisplayLuminance.BoostContext(currentHeadroom: 1.2, maximumHDRNits: 1600)
        for factor in [1.0, 1.1, 1.5, 2.0] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                                        boostActive: true, boostContext: context)
            XCTAssertNil(value.nits, "Slider position cannot establish emitted luminance")
            XCTAssertEqual(try XCTUnwrap(value.availableHDRNits), 480, accuracy: 0.000001)
            XCTAssertEqual(value.text, "HDR ≤480 nits")
            XCTAssertTrue(value.accessibilityText.contains("capacity"))
            XCTAssertTrue(value.explanation.contains("not the brightness reached"))
        }
    }

    func testPreset1600AloneCannotProduce1600CurrentNits() {
        let value = DisplayLuminance(referenceNits: 400, appliedFactor: 2,
            boostActive: true, boostContext: .init(currentHeadroom: 1.2, maximumHDRNits: 1600))
        XCTAssertNil(value.nits)
        XCTAssertEqual(value.availableHDRNits, 480)
        XCTAssertFalse(value.text.contains("1600"))
    }

    func testCurrentHeadroomNotSliderDeterminesAvailableCapacity() throws {
        for (headroom, expected) in [(1.0, 400.0), (1.2, 480), (2.0, 800), (3.0, 1200)] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: 1.5,
                boostActive: true, boostContext: .init(currentHeadroom: headroom, maximumHDRNits: 1600))
            XCTAssertNil(value.nits)
            XCTAssertEqual(try XCTUnwrap(value.availableHDRNits), expected, accuracy: 0.000001)
        }
    }

    func testSystemAbsoluteCapacityUsesItsOwnReferenceBasis() {
        let value = DisplayLuminance(referenceNits: 350, appliedFactor: 2,
            boostActive: true, boostContext: .init(currentHeadroom: 16,
                maximumHDRNits: 1600, availablePeakNits: 400 * 2))
        XCTAssertNil(value.nits)
        XCTAssertEqual(value.availableHDRNits, 800)
        XCTAssertEqual(value.text, "HDR ≤800 nits")
    }

    func testInvalidReportedAvailabilityCannotInflateCapacity() {
        for available: Double in [-1, .nan, .infinity] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: 2,
                boostActive: true, boostContext: .init(currentHeadroom: 3,
                    maximumHDRNits: 1600, availablePeakNits: available))
            XCTAssertNil(value.availableHDRNits)
        }
    }

    func testCapacityIsBoundedWithoutOverflow() {
        for headroom in [4.0, 8.0, Double.greatestFiniteMagnitude] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: 2,
                boostActive: true, boostContext: .init(currentHeadroom: headroom, maximumHDRNits: 1600))
            XCTAssertNil(value.nits)
            XCTAssertEqual(value.availableHDRNits, 1600)
            XCTAssertEqual(value.text, "HDR ≤1600 nits")
        }
    }

    func testInvalidCapacityContextIsUnavailable() {
        var contexts: [DisplayLuminance.BoostContext] = []
        for invalid: Double in [-1, 0, 0.5, .infinity, -.infinity, .nan] {
            contexts.append(.init(currentHeadroom: invalid, maximumHDRNits: 1600))
        }
        for invalid: Double in [-1, 0, 399, .infinity, -.infinity, .nan] {
            contexts.append(.init(currentHeadroom: 3, maximumHDRNits: invalid))
        }
        for context in contexts {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: 1.5,
                                         boostActive: true, boostContext: context)
            XCTAssertNil(value.nits)
            XCTAssertNil(value.availableHDRNits)
            XCTAssertEqual(value.text, "— nits")
        }
    }

    func testCapacityCannotMakeInvalidOrPendingAdjustmentsLookSettled() {
        let context = DisplayLuminance.BoostContext(currentHeadroom: 3, maximumHDRNits: 1600)
        for factor: Double in [-1, 0, 0.5, .infinity, -.infinity, .nan] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                                        boostActive: true, boostContext: context)
            XCTAssertNil(value.nits)
            XCTAssertNil(value.availableHDRNits)
        }
        for reference: Double? in [nil, -1, .infinity, -.infinity, .nan] {
            let value = DisplayLuminance(referenceNits: reference, appliedFactor: 1.5,
                                        boostActive: true, boostContext: context)
            XCTAssertNil(value.nits)
            XCTAssertNil(value.availableHDRNits)
        }
        let normal = DisplayLuminance(referenceNits: 400, appliedFactor: 1, boostContext: context)
        XCTAssertEqual(normal.nits, 400)
        XCTAssertNil(normal.availableHDRNits)
    }

    func testUnknownDimmingResponseDoesNotPreventNativeReadout() {
        XCTAssertEqual(DisplayLuminance(referenceNits: 400.2, appliedFactor: 1, dimmingTransfer: nil).nits, 400.2)
        XCTAssertNil(DisplayLuminance(referenceNits: 400.2, appliedFactor: 0.5, dimmingTransfer: nil).nits)
    }

    func testExplicitPowerResponseAndInvalidGamma() throws {
        let value = DisplayLuminance(referenceNits: 400, appliedFactor: 0.5, dimmingTransfer: .power(exponent: 2))
        XCTAssertEqual(try XCTUnwrap(value.nits), 100, accuracy: 0.000001)
        for gamma: Double in [0, -1, .infinity, .nan] {
            XCTAssertNil(DisplayLuminance(referenceNits: 400, appliedFactor: 0.5, dimmingTransfer: .power(exponent: gamma)).nits)
        }
    }

    func testDisplayPrecisionRetainsVeryDimValues() {
        XCTAssertEqual(DisplayLuminance(referenceNits: 4.25, appliedFactor: 1).text, "≈4.2 nits")
        XCTAssertEqual(DisplayLuminance(referenceNits: 0.0342, appliedFactor: 1).text, "≈0.034 nits")
        XCTAssertEqual(DisplayLuminance(referenceNits: 0.0000342, appliedFactor: 1).text, "≈3.4e-05 nits")
    }
}
