import Foundation

/// An SDR-white estimate from a system-derived reference, not a photometer
/// measurement or the luminance of every pixel on the screen.
public struct DisplayLuminance: Equatable, Sendable {
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
                boostActive: Bool = false, dimmingTransfer: DimmingTransfer? = .sRGB) {
        self.referenceNits = referenceNits.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard appliedFactor.isFinite, appliedFactor >= 0 else {
            nits = nil
            explanation = "Nits unavailable: the applied brightness adjustment is unknown."
            return
        }
        guard !boostActive, appliedFactor <= 1 else {
            nits = nil
            explanation = "Nits unavailable during extra brightness: transfer-table scaling and EDR headroom do not establish actual luminance."
            return
        }
        guard let reference = self.referenceNits else {
            nits = nil
            explanation = "Nits unavailable: macOS did not provide a usable linear brightness and SDR reference for this display."
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
