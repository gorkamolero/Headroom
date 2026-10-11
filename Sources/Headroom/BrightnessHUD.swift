import AppKit
import SwiftUI

/// A nonactivating display indicator made from Apple's slider and glass controls.
/// The private legacy OSD service ignores requests on recent macOS versions.
final class BrightnessHUD {
    private let state = BrightnessHUDState()
    private var panel: BrightnessHUDPanel?
    private var dismissal: Timer?
    private var presentation = 0

    func show(screen: NSScreen, factor: Double, maximum: Double,
              preparing: Bool = false, message: String? = nil) {
        guard factor.isFinite, maximum.isFinite else { return }
        present(screen: screen, level: factor / max(1, maximum), duration: 1.5)
    }

    /// Displays the production view without changing brightness or starting a session.
    func showPreview(screen: NSScreen, level: Double, duration: TimeInterval = 30) {
        guard level.isFinite, duration.isFinite else { return }
        present(screen: screen, level: level, duration: max(0.1, duration))
    }

    func hide() {
        presentation += 1
        dismissal?.invalidate()
        dismissal = nil
        panel?.orderOut(nil)
    }

    private func present(screen: NSScreen, level: Double, duration: TimeInterval) {
        if panel == nil { makePanel() }
        guard let panel else { return }
        presentation += 1
        let currentPresentation = presentation
        dismissal?.invalidate()
        state.level = min(1, max(0, level))
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 4,
                                     y: visible.maxY - panel.frame.height - 2))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self, self.presentation == currentPresentation else { return }
            self.dismissal = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.presentation == currentPresentation else { return }
                panel.orderOut(nil)
            }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func makePanel() {
        // The transparent inset leaves room for the native glass highlight and shadow.
        let panel = BrightnessHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 306, height: 78),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.title = "Headroom Brightness"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        let content = NSHostingView(rootView: BrightnessHUDContent(state: state))
        content.frame = NSRect(x: 0, y: 0, width: 290, height: 62)
        content.sizingOptions = []
        let glassFrame = NSRect(x: 8, y: 8, width: 290, height: 62)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: glassFrame)
            glass.style = .regular
            glass.cornerRadius = 24
            glass.tintColor = NSColor(white: 0.12, alpha: 0.35)
            glass.contentView = content
            root.addSubview(glass)
        } else {
            let glass = NSVisualEffectView(frame: glassFrame)
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 24
            glass.layer?.masksToBounds = true
            glass.addSubview(content)
            root.addSubview(glass)
        }
        panel.contentView = root
        self.panel = panel
    }

    deinit { dismissal?.invalidate() }
}

private final class BrightnessHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BrightnessHUDState: ObservableObject {
    @Published var level = 0.0
}

private struct BrightnessHUDContent: View {
    @ObservedObject var state: BrightnessHUDState
    private let ticks = Array(stride(from: 0.0, through: 1.0, by: 1.0 / 16))

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("Display +")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 130, alignment: .leading)
                .position(x: 79, y: 17.5)
            Image(systemName: "sun.min.fill")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .position(x: 19, y: 41)
            slider
                .tint(.white)
                .controlSize(.small)
                .frame(width: 225, height: 22)
                .position(x: 143.5, y: 41)
                .accessibilityLabel("Display + brightness")
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .position(x: 268, y: 41)
        }
        .frame(width: 290, height: 62)
        .preferredColorScheme(.dark)
        .environment(\.appearsActive, true)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var slider: some View {
        if #available(macOS 26, *) {
            Slider(value: .constant(state.level)) {} ticks: {
                SliderTickContentForEach(ticks, id: \.self) { value in
                    SliderTick(value)
                }
            }
            .sliderThumbVisibility(.hidden)
        } else {
            Slider(value: .constant(state.level), in: 0...1)
        }
    }
}
