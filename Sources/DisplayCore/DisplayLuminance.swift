import Foundation

/// An SDR-white estimate from a system-derived reference, not a photometer
/// measurement or the luminance of every pixel on the screen.
public struct DisplayLuminance: Equatable, Sendable {
    /// Capabilities used by the uncalibrated boost model. Headroom describes
    /// the current display state; maximumFactor is the configured control
    /// range, which must not shrink when current headroom changes.
    public struct BoostContext: Equatable, Sendable {
        public let currentHeadroom: Double
        public let maximumHDRNits: Double
        public let maximumFactor: Double

        public init(currentHeadroom: Double, maximumHDRNits: Double,
                    maximumFactor: Double) {
            self.currentHeadroom = currentHeadroom
            self.maximumHDRNits = maximumHDRNits
            self.maximumFactor = maximumFactor
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
    public let nits: Double?
    public let explanation: String

    /// `referenceNits` is the current native SDR-white estimate, already
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
            guard appliedFactor >= 1, let context = boostContext,
                  context.currentHeadroom.isFinite, context.currentHeadroom >= 1,
                  context.maximumHDRNits.isFinite, context.maximumHDRNits > 0,
                  context.maximumHDRNits >= reference,
                  context.maximumFactor.isFinite, context.maximumFactor > 1 else {
                nits = nil
                explanation = "Nits unavailable during extra brightness: a valid applied boost, current EDR headroom, HDR preset limit, and configured boost range are required."
                return
            }

            // Apple defines EDR headroom as peak white / SDR reference white.
            // That bounds capacity, not the response to a gamma-table change.
            // Interpolating the confirmed control position within that bound
            // is our stated model; it is not a measured transfer function.
            // Compare before multiplying to avoid overflow on extreme inputs.
            let ceiling = reference > 0 && context.currentHeadroom >= context.maximumHDRNits / reference
                ? context.maximumHDRNits
                : reference * context.currentHeadroom
            let progress = min(1, max(0, (appliedFactor - 1) / (context.maximumFactor - 1)))
            nits = min(ceiling, reference + progress * (ceiling - reference))
            explanation = "Uncalibrated boost estimate: an assumed response interpolates the confirmed boost position from native SDR white to the available HDR ceiling, bounded by current EDR headroom and the preset HDR limit. This models display capability; it is not a physical luminance measurement or a calibrated transfer-table response."
            return
        }
        guard appliedFactor <= 1 else {
            nits = nil
            explanation = "Nits unavailable: an applied boost requires an active boost session and its display context."
            return
        }
        guard appliedFactor < 1 else {
            nits = reference
            explanation = "Estimated SDR white from macOS linear brightness × the active display preset's SDR maximum. Not a physical measurement."
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
        return "≈\(number) nits"
    }
}
