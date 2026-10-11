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

    func testBoostInterpolatesContinuouslyFromNativeToAvailablePeak() throws {
        let context = DisplayLuminance.BoostContext(currentHeadroom: 3,
                                                   maximumHDRNits: 1600,
                                                   maximumFactor: 2)
        let native = DisplayLuminance(referenceNits: 400, appliedFactor: 1)
        for (factor, expected) in [(1.0, 400.0), (1.5, 800), (2.0, 1200)] {
            let value = DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                                         boostActive: true, boostContext: context)
            XCTAssertEqual(try XCTUnwrap(value.nits), expected, accuracy: 0.000001)
            XCTAssertTrue(value.text.hasPrefix("≈"))
            XCTAssertTrue(value.explanation.contains("Uncalibrated"))
            XCTAssertTrue(value.explanation.contains("not a physical luminance measurement"))
        }
        XCTAssertEqual(DisplayLuminance(referenceNits: 400, appliedFactor: 1,
                        boostActive: true, boostContext: context).nits, native.nits)
    }

    func testHeadroomDropLowersEstimateWithoutRenormalizingBoostPosition() throws {
        // The configured range stays at 2 even when current headroom falls.
        // At halfway boost, available headroom 1.2 yields 440, not 480 nits.
        let context = DisplayLuminance.BoostContext(currentHeadroom: 1.2,
                                                   maximumHDRNits: 1600,
                                                   maximumFactor: 2)
        let value = DisplayLuminance(referenceNits: 400, appliedFactor: 1.5,
                                     boostActive: true, boostContext: context)
        XCTAssertEqual(try XCTUnwrap(value.nits), 440, accuracy: 0.000001)
    }

    func testBoostUsesHDRLimitAsCeilingNotAnAdditionalMultiplier() throws {
        let context = DisplayLuminance.BoostContext(currentHeadroom: 8,
                                                   maximumHDRNits: 1600,
                                                   maximumFactor: 2)
        let middle = DisplayLuminance(referenceNits: 600, appliedFactor: 1.5,
                                      boostActive: true, boostContext: context)
        let top = DisplayLuminance(referenceNits: 600, appliedFactor: 2,
                                   boostActive: true, boostContext: context)
        XCTAssertEqual(try XCTUnwrap(middle.nits), 1100, accuracy: 0.000001)
        XCTAssertEqual(top.nits, 1600)
    }

    func testBoostNeverInventsGainWhenCurrentHeadroomIsOne() {
        let context = DisplayLuminance.BoostContext(currentHeadroom: 1,
                                                   maximumHDRNits: 1600,
                                                   maximumFactor: 2)
        for factor in [1.0, 1.5, 2, 3] {
            XCTAssertEqual(DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                            boostActive: true, boostContext: context).nits, 400)
        }
    }

    func testBoostIsMonotonicWithAppliedFactorHeadroomAndNativeReference() throws {
        func estimate(reference: Double, factor: Double, headroom: Double) throws -> Double {
            try XCTUnwrap(DisplayLuminance(referenceNits: reference, appliedFactor: factor,
                boostActive: true, boostContext: .init(currentHeadroom: headroom,
                    maximumHDRNits: 1600, maximumFactor: 2)).nits)
        }
        var previousFactor = 0.0
        var previousHeadroom = 0.0
        var previousReference = 0.0
        for step in 0...100 {
            let factorValue = try estimate(reference: 400, factor: 1 + Double(step) / 100, headroom: 3)
            let headroomValue = try estimate(reference: 400, factor: 1.5, headroom: 1 + Double(step) / 10)
            let referenceValue = try estimate(reference: Double(step) * 10, factor: 1.5, headroom: 3)
            XCTAssertGreaterThanOrEqual(factorValue, previousFactor)
            XCTAssertGreaterThanOrEqual(headroomValue, previousHeadroom)
            XCTAssertGreaterThanOrEqual(referenceValue, previousReference)
            XCTAssertLessThanOrEqual(max(factorValue, headroomValue, referenceValue), 1600)
            previousFactor = factorValue
            previousHeadroom = headroomValue
            previousReference = referenceValue
        }
    }

    func testBoostClampsPastConfiguredMaximumAndAvoidsOverflow() {
        let context = DisplayLuminance.BoostContext(currentHeadroom: 3,
                                                   maximumHDRNits: 1600,
                                                   maximumFactor: 2)
        for factor in [2.0, 3, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                            boostActive: true, boostContext: context).nits, 1200)
        }
        let extreme = DisplayLuminance(referenceNits: 400, appliedFactor: 2,
            boostActive: true, boostContext: .init(currentHeadroom: .greatestFiniteMagnitude,
                maximumHDRNits: 1600, maximumFactor: 2))
        XCTAssertEqual(extreme.nits, 1600)
    }

    func testInvalidBoostContextIsUnavailable() {
        var contexts: [DisplayLuminance.BoostContext] = []
        for invalid: Double in [-1, 0, 0.5, .infinity, -.infinity, .nan] {
            contexts.append(.init(currentHeadroom: invalid, maximumHDRNits: 1600, maximumFactor: 2))
        }
        for invalid: Double in [-1, 0, 399, .infinity, -.infinity, .nan] {
            contexts.append(.init(currentHeadroom: 3, maximumHDRNits: invalid, maximumFactor: 2))
        }
        for invalid: Double in [-1, 0, 0.5, 1, .infinity, -.infinity, .nan] {
            contexts.append(.init(currentHeadroom: 3, maximumHDRNits: 1600, maximumFactor: invalid))
        }
        for context in contexts {
            for factor in [1.0, 1.5, 2] {
                let value = DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                                             boostActive: true, boostContext: context)
                XCTAssertNil(value.nits)
                XCTAssertEqual(value.text, "— nits")
            }
        }
    }

    func testBoostContextCannotTurnInvalidOrInactiveAdjustmentsIntoBoost() {
        let context = DisplayLuminance.BoostContext(currentHeadroom: 3,
                                                   maximumHDRNits: 1600,
                                                   maximumFactor: 2)
        for factor: Double in [-1, 0, 0.5, .infinity, -.infinity, .nan] {
            XCTAssertNil(DisplayLuminance(referenceNits: 400, appliedFactor: factor,
                            boostActive: true, boostContext: context).nits)
        }
        for reference: Double? in [nil, -1, .infinity, -.infinity, .nan] {
            XCTAssertNil(DisplayLuminance(referenceNits: reference, appliedFactor: 1.5,
                            boostActive: true, boostContext: context).nits)
        }
        XCTAssertNil(DisplayLuminance(referenceNits: 400, appliedFactor: 1.5,
                        boostContext: context).nits)
        XCTAssertEqual(DisplayLuminance(referenceNits: 400, appliedFactor: 1,
                        boostContext: context).nits, 400)
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
