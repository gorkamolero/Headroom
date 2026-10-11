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

    func testBoostPredictionUsesExplicitExtendedSRGBHypothesis() throws {
        // Independently evaluated with 40-digit Decimal arithmetic. These
        // verify the calculation, not the panel's physical response.
        for (factor, expected) in [(1.0, 400.2), (1.1, 497.3566662559813),
                                   (1.2, 607.038342161883), (1.5, 1015.3695268044852)] {
            let value = DisplayLuminance(referenceNits: 400.2, appliedFactor: factor,
                boostActive: true, boostContext: .init(currentHeadroom: 4, maximumHDRNits: 1600))
            XCTAssertEqual(try XCTUnwrap(value.nits), expected, accuracy: 0.000001)
            XCTAssertEqual(value.availableHDRNits, 1600)
            XCTAssertTrue(value.isModeledBoost)
            XCTAssertTrue(value.text.hasSuffix(" nits est."))
            XCTAssertTrue(value.accessibilityText.contains("Uncalibrated"))
            XCTAssertTrue(value.explanation.contains("Actual output may differ"))
        }
    }

    func testBoostEstimateIsContinuousAndMonotonicAcrossNativeBoundary() throws {
        var previous = 0.0
        for step in 999...2000 {
            let factor = Double(step) / 1000
            let value = DisplayLuminance(referenceNits: 400.2, appliedFactor: factor,
                boostActive: factor >= 1,
                boostContext: .init(currentHeadroom: 4, maximumHDRNits: 1600))
            let current = try XCTUnwrap(value.nits)
            XCTAssertGreaterThanOrEqual(current, previous)
            XCTAssertLessThanOrEqual(current, 1600)
            previous = current
        }
        let near = DisplayLuminance(referenceNits: 400.2, appliedFactor: 1.000001,
            boostActive: true, boostContext: .init(currentHeadroom: 4, maximumHDRNits: 1600))
        XCTAssertEqual(try XCTUnwrap(near.nits), 400.200910408187, accuracy: 0.000001)
    }

    func testCapacityRemainsIndependentOfPredictionAndSliderPosition() throws {
        for headroom in [3.0, 4.0, 8.0] {
            let value = DisplayLuminance(referenceNits: 400.2, appliedFactor: 1.2,
                boostActive: true, boostContext: .init(currentHeadroom: headroom, maximumHDRNits: 1600))
            XCTAssertEqual(try XCTUnwrap(value.nits), 607.038342161883, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(value.availableHDRNits), min(400.2 * headroom, 1600), accuracy: 0.000001)
        }
    }

    func testPreset1600AloneCannotProduce1600Estimate() {
        let value = DisplayLuminance(referenceNits: 400, appliedFactor: 2,
            boostActive: true, boostContext: .init(currentHeadroom: 1.2, maximumHDRNits: 1600))
        XCTAssertEqual(value.nits, 480)
        XCTAssertEqual(value.availableHDRNits, 480)
        XCTAssertEqual(value.text, "≈480 nits est.")
    }

    func testFallingCurrentHeadroomCapsPredictionAtNativeWhite() throws {
        for (headroom, expected) in [(1.0, 400.0), (1.2, 480), (2.0, 800)] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: 1.5,
                boostActive: true, boostContext: .init(currentHeadroom: headroom, maximumHDRNits: 1600))
            XCTAssertEqual(try XCTUnwrap(value.nits), expected, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(value.availableHDRNits), expected, accuracy: 0.000001)
        }
    }

    func testSystemAbsoluteCapacityUsesItsOwnReferenceBasis() {
        let value = DisplayLuminance(referenceNits: 350, appliedFactor: 2,
            boostActive: true, boostContext: .init(currentHeadroom: 16,
                maximumHDRNits: 1600, availablePeakNits: 400 * 2))
        XCTAssertEqual(value.nits, 800)
        XCTAssertEqual(value.availableHDRNits, 800)
        XCTAssertEqual(value.text, "≈800 nits est.")
    }

    func testInvalidReportedAvailabilityCannotInflateCapacity() {
        for available: Double in [-1, .nan, .infinity] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: 2,
                boostActive: true, boostContext: .init(currentHeadroom: 3,
                    maximumHDRNits: 1600, availablePeakNits: available))
            XCTAssertNil(value.availableHDRNits)
            XCTAssertNil(value.nits)
        }
        let inconsistent = DisplayLuminance(referenceNits: 400, appliedFactor: 2,
            boostActive: true, boostContext: .init(currentHeadroom: 3,
                maximumHDRNits: 1600, availablePeakNits: 399))
        XCTAssertNil(inconsistent.nits)
        XCTAssertFalse(inconsistent.isModeledBoost)
        XCTAssertEqual(inconsistent.text, "— nits")
    }

    func testPredictionIsBoundedWithoutIntermediateOverflow() {
        for headroom in [4.0, 8.0, Double.greatestFiniteMagnitude] {
            for factor in [2.0, Double.greatestFiniteMagnitude] {
                let value = DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                    boostActive: true, boostContext: .init(currentHeadroom: headroom, maximumHDRNits: 1600))
                XCTAssertEqual(value.nits, 1600)
                XCTAssertEqual(value.availableHDRNits, 1600)
                XCTAssertEqual(value.text, "≈1600 nits est.")
            }
        }
    }

    func testZeroNativeReferenceRemainsZeroInBoost() {
        let value = DisplayLuminance(referenceNits: 0, appliedFactor: 2,
            boostActive: true, boostContext: .init(currentHeadroom: 4, maximumHDRNits: 1600))
        XCTAssertEqual(value.nits, 0)
        XCTAssertEqual(value.availableHDRNits, 0)
        XCTAssertEqual(value.text, "≈0 nits est.")
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
