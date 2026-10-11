import Foundation

/// System-derived native white and explicitly modeled dim/boost predictions.
/// HDR capacity remains separate. None is an optical measurement.
public struct DisplayLuminance: Equatable, Sendable {
    /// Current display capability, independent of the boost slider position.
    /// It cannot establish the luminance of gamma-adjusted desktop content.
    public struct BoostContext: Equatable, Sendable {
        public let currentHeadroom: Double
        public let maximumHDRNits: Double
        public let availablePeakNits: Double?

        public init(currentHeadroom: Double, maximumHDRNits: Double, availablePeakNits: Double? = nil) {
            self.currentHeadroom = currentHeadroom
            self.maximumHDRNits = maximumHDRNits
            self.availablePeakNits = availablePeakNits
        }
    }

    /// A stated assumption about the output response after transfer-table
    /// scaling. The display profile alone does not calibrate this whole path.
    public enum DimmingTransfer: Equatable, Sendable {
        case sRGB
        case power(exponent: Double)

        fileprivate func linearFraction(_ encoded: Double) -> Double? {
            switch self {
            case .sRGB:
                return encoded <= 0.04045
                    ? encoded / 12.92
                    : pow((encoded + 0.055) / 1.055, 2.4)
            case .power(let exponent):
                guard exponent.isFinite, exponent > 0 else { return nil }
                return pow(encoded, exponent)
            }
        }

        fileprivate var description: String {
            switch self {
            case .sRGB: return "an assumed sRGB display response"
            case .power(let exponent): return "an assumed gamma-\(exponent) display response"
            }
        }
    }

    public let referenceNits: Double?
    /// Native white or a prediction under the stated transfer assumption.
    public let nits: Double?
    public private(set) var isModeledBoost = false
    /// Current HDR ceiling, never represented as attained desktop brightness.
    public private(set) var availableHDRNits: Double? = nil
    public let explanation: String

    /// `referenceNits` is live system-reported SDR white, or the fallback
    /// calculated from linear brightness and the active preset's SDR maximum.
    /// `appliedFactor` is the helper-acknowledged table write parameter, not a queued
    /// slider target. Apple documents Display P3 as using the sRGB transfer:
    /// https://developer.apple.com/documentation/coregraphics/cgcolorspace/displayp3
    /// This motivates the default assumption; it does not validate the panel's
    /// final luminance after a Core Graphics transfer-table change.
    public init(referenceNits: Double?, appliedFactor: Double,
                boostActive: Bool = false, dimmingTransfer: DimmingTransfer? = .sRGB,
                boostContext: BoostContext? = nil) {
        self.referenceNits = referenceNits.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard appliedFactor.isFinite, appliedFactor >= 0 else {
            nits = nil
            explanation = "Nits unavailable: the applied brightness adjustment is unknown."
            return
        }
        guard let reference = self.referenceNits else {
            nits = nil
            explanation = "Nits unavailable: macOS did not provide a usable linear brightness and SDR reference for this display."
            return
        }
        if boostActive {
            guard appliedFactor >= 1, let context = boostContext,
                  context.currentHeadroom.isFinite, context.currentHeadroom >= 1,
                  context.maximumHDRNits.isFinite, context.maximumHDRNits > 0,
                  context.maximumHDRNits >= reference,
                  context.availablePeakNits.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                nits = nil
                explanation = "Boost estimate unavailable: macOS did not provide a usable native nits reference and current HDR capacity."
                return
            }
            // Capacity is an independent ceiling, never a slider endpoint.
            // Keep the private available-peak bound in its own reference basis.
            let limit = min(context.maximumHDRNits, context.availablePeakNits ?? .infinity)
            let capacity = reference > 0 && context.currentHeadroom >= limit / reference
                ? limit
                : reference * context.currentHeadroom
            availableHDRNits = capacity
            guard capacity >= reference else {
                nits = nil
                explanation = "Boost estimate unavailable: current HDR capacity is below the native nits reference."
                return
            }

            // Explicit hypothesis: the acknowledged table gain behaves as
            // encoded RGB gain that survives into EDR. Decode it with the
            // extended sRGB EOTF, rather than stretching a slider to its max.
            // https://www.w3.org/TR/css-color-4/#color-conversion-code
            // Apple's normalized gamma readback clamps above 1 on the test
            // host: it does NOT verify this hypothesis. This predicts output
            // under the assumption; it is not a calibrated panel response.
            isModeledBoost = true
            if reference == 0 || appliedFactor == 1 {
                nits = reference
            } else {
                // Algebraically B * ((f + .055) / 1.055)^2.4. Log space
                // avoids overflowing the intermediate gain for extreme input.
                let logPrediction = log(reference)
                    + 2.4 * log1p((appliedFactor - 1) / 1.055)
                nits = logPrediction >= log(capacity)
                    ? capacity : max(reference, min(capacity, exp(logPrediction)))
            }
            explanation = "Uncalibrated boost estimate assuming an extended-sRGB light response to the acknowledged adjustment. Actual output may differ: normalized display-table readback does not establish this response. Available HDR ceiling: approximately \(Self.number(capacity)) nits. This is a calculated prediction, not a measurement."
            return
        }
        guard appliedFactor <= 1 else {
            nits = nil
            explanation = "Nits unavailable: an applied boost requires an active boost session and its display context."
            return
        }
        guard appliedFactor < 1 else {
            nits = reference
            explanation = "SDR white reported by macOS, with linear brightness × the active SDR preset as a fallback. Not a physical measurement."
            return
        }
        guard let transfer = dimmingTransfer,
              let fraction = transfer.linearFraction(appliedFactor),
              fraction.isFinite, fraction >= 0, fraction <= 1 else {
            nits = nil
            explanation = "Nits unavailable during extra dimming: no usable display-response assumption is available."
            return
        }
        nits = reference * fraction
        explanation = "Estimated SDR white after extra dimming, using the native nits reference and \(transfer.description). Transfer-table scale is not a measured luminance multiplier."
    }

    public var text: String {
        guard let nits else { return "— nits" }
        return "≈\(Self.number(nits)) nits" + (isModeledBoost ? " est." : "")
    }

    public var accessibilityText: String {
        if isModeledBoost, let nits {
            return "Calculated boost estimate: approximately \(Self.number(nits)) nits. Uncalibrated extended-sRGB assumption; actual output may differ."
        }
        return "Estimated SDR white: \(text)"
    }

    private static func number(_ nits: Double) -> String {
        let format: String
        if nits == 0 || nits >= 10 {
            format = "%.0f"
        } else if nits >= 1 {
            format = "%.1f"
        } else {
            // Significant digits preserve small dimmed values instead of
            // misleadingly rounding a nonzero estimate to zero.
            format = "%.2g"
        }
        let number = String(format: format, locale: Locale(identifier: "en_US_POSIX"), nits).lowercased()
        return number
    }
}
