import AppKit
import SwiftUI

struct BrightnessHUDPresentation {
    static let lowerRangeBoundary = 2.0 / 16
    static let upperRangeBoundary = 14.0 / 16
    let title: String
    let level: Double
    let lowerBoundary: Double?
    let upperBoundary: Double?
}

/// A nonactivating display indicator made from Apple's slider and glass controls.
/// The private legacy OSD service ignores requests on recent macOS versions.
final class BrightnessHUD {
    private let state = BrightnessHUDState()
    private var panel: BrightnessHUDPanel?
    private var dismissal: Timer?
    private var presentationGeneration = 0
    private(set) var presentation: BrightnessHUDPresentation?

    func show(screen: NSScreen, presentation: BrightnessHUDPresentation) {
        guard presentation.level.isFinite else { return }
        present(screen: screen, presentation: presentation, duration: 1.5)
    }

    /// Displays the production view without changing brightness or starting a session.
    func showPreview(screen: NSScreen, level: Double, duration: TimeInterval = 30) {
        guard level.isFinite, duration.isFinite else { return }
        present(screen: screen, presentation: BrightnessHUDPresentation(title: "Display", level: level,
            lowerBoundary: BrightnessHUDPresentation.lowerRangeBoundary,
            upperBoundary: BrightnessHUDPresentation.upperRangeBoundary), duration: max(0.1, duration))
    }

    func hide() {
        presentationGeneration += 1
        dismissal?.invalidate()
        dismissal = nil
        panel?.orderOut(nil)
    }

    private func present(screen: NSScreen, presentation: BrightnessHUDPresentation, duration: TimeInterval) {
        if panel == nil { makePanel() }
        guard let panel else { return }
        presentationGeneration += 1
        let currentPresentation = presentationGeneration
        dismissal?.invalidate()
        self.presentation = presentation
        state.presentation = presentation
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 4,
                                     y: visible.maxY - panel.frame.height - 2))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self, self.presentationGeneration == currentPresentation else { return }
            self.dismissal = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.presentationGeneration == currentPresentation else { return }
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
    @Published var presentation = BrightnessHUDPresentation(title: "Display", level: 0,
        lowerBoundary: nil, upperBoundary: nil)
}

private struct BrightnessHUDContent: View {
    @ObservedObject var state: BrightnessHUDState

    // Every tick stays on the same grid. Boundaries change height only.
    private var ticks: [(position: Double, isBoundary: Bool)] {
        let boundaries = [state.presentation.lowerBoundary, state.presentation.upperBoundary]
            .compactMap { $0 }.filter { $0.isFinite && $0 > 0 && $0 < 1 }
        return (0...16).map { index in
            let position = Double(index) / 16
            return (position, boundaries.contains(position))
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(state.presentation.title)
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
                .overlay(alignment: .topLeading) {
                    ForEach(ticks.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(.white.opacity(0.4))
                            .frame(width: 2, height: ticks[index].isBoundary ? 12 : 8)
                            .position(x: 1 + 223 * ticks[index].position, y: 11)
                            .accessibilityHidden(true)
                    }
                }
                .position(x: 143.5, y: 41)
                .accessibilityLabel("\(state.presentation.title) brightness")
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
            Slider(value: .constant(min(1, max(0, state.presentation.level))), in: 0...1)
                .sliderThumbVisibility(.hidden)
        } else {
            Slider(value: .constant(min(1, max(0, state.presentation.level))), in: 0...1)
        }
    }
}
