import AppKit

/// A transient indicator for Headroom's boost setting, not measured luminance.
/// Call on the main thread, including from the menu's tracking run loop.
final class BrightnessHUD {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: Panel
    private let value = NSTextField(labelWithString: "1.00×")
    private let subtitle = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var hideTimer: Timer?

    init() {
        let bounds = NSRect(x: 0, y: 0, width: 264, height: 102)
        panel = Panel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Headroom brightness boost")

        let material = NSVisualEffectView(frame: bounds)
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 16
        material.layer?.masksToBounds = true
        panel.contentView = material

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: "Brightness boost")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        value.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        value.textColor = .labelColor
        value.alignment = .right
        value.setAccessibilityLabel("Boost setting")

        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.setAccessibilityLabel("Available boost range")

        for view in [icon, title, value, progress, subtitle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 17),
            icon.topAnchor.constraint(equalTo: material.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -8),
            value.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -17),
            value.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 17),
            progress.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -17),
            progress.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 13),
            progress.heightAnchor.constraint(equalToConstant: 8),
            subtitle.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8)
        ])
    }

    func show(screen: NSScreen, factor: Double, maximum: Double,
              preparing: Bool = false, message: String? = nil) {
        hideTimer?.invalidate()
        let safeMaximum = maximum.isFinite ? max(1, maximum) : 1
        let safeFactor = factor.isFinite ? min(safeMaximum, max(1, factor)) : 1
        value.stringValue = String(format: "%.2f×", safeFactor)
        value.setAccessibilityValue(String(format: "%.2f times boost setting", safeFactor))
        subtitle.stringValue = message ?? (preparing ? "Preparing boost…" :
            (safeFactor <= 1.001 ? "Normal brightness" : "Headroom · \(screen.localizedName)"))
        subtitle.toolTip = subtitle.stringValue
        progress.doubleValue = safeMaximum > 1 ? (safeFactor - 1) / (safeMaximum - 1) : 0
        progress.setAccessibilityValue("\(Int((progress.doubleValue * 100).rounded())) percent")
        panel.setAccessibilityValue("\(value.stringValue). \(subtitle.stringValue)")

        // visibleFrame avoids the Dock and works for displays with negative origins.
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = max(visible.minX, min(visible.maxX - size.width, visible.midX - size.width / 2))
        let bottomInset = max(24, min(100, visible.height * 0.12))
        let y = max(visible.minY, min(visible.maxY - size.height, visible.minY + bottomInset))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.35, repeats: false) { [weak self] _ in self?.hide() }
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }

    deinit {
        hideTimer?.invalidate()
        panel.close()
    }
}
