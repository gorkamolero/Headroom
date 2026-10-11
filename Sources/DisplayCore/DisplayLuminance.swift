import Foundation

/// System-derived SDR white, an explicitly assumed dimming estimate, or
/// separately identified HDR capacity. None is an optical measurement.
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
    /// Estimated current SDR white; deliberately unavailable during boost.
    public let nits: Double?
    /// Current HDR ceiling, never represented as attained desktop brightness.
    public private(set) var availableHDRNits: Double? = nil
    public let explanation: String

    /// `referenceNits` is live system-reported SDR white, or the fallback
    /// calculated from linear brightness and the active preset's SDR maximum.
    /// `appliedFactor` must describe a confirmed table adjustment, not a queued
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
            nits = nil
            guard appliedFactor >= 1, let context = boostContext,
                  context.currentHeadroom.isFinite, context.currentHeadroom >= 1,
                  context.maximumHDRNits.isFinite, context.maximumHDRNits > 0,
                  context.maximumHDRNits >= reference,
                  context.availablePeakNits.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                explanation = "Boosted desktop nits are unknown. Current HDR capacity is unavailable because macOS did not provide a usable SDR reference and HDR headroom."
                return
            }
            // Apple defines current EDR capacity as SDR white × headroom.
            // This is a ceiling. A gamma-table factor does NOT identify an
            // EDR pixel value or a fraction of that capacity. No interpolation.
            let limit = min(context.maximumHDRNits, context.availablePeakNits ?? .infinity)
            availableHDRNits = reference > 0 && context.currentHeadroom >= limit / reference
                ? limit
                : reference * context.currentHeadroom
            explanation = "Current HDR capacity from macOS: SDR white × current EDR headroom, capped by the HDR limit. This is an upper bound, not the brightness reached by the desktop. The effect of the boost transfer table is not calibrated in nits."
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
        if let availableHDRNits { return "HDR ≤\(Self.number(availableHDRNits)) nits" }
        guard let nits else { return "— nits" }
        return "≈\(Self.number(nits)) nits"
    }

    public var accessibilityText: String {
        if let availableHDRNits {
            return "Current HDR capacity: approximately \(Self.number(availableHDRNits)) nits. Boosted desktop luminance is unknown."
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
