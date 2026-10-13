import AppKit
import ServiceManagement

/// macOS owns the preference; a second saved boolean would drift from Settings.
final class OpenAtLoginController: NSObject {
    let menuItem = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")
    let approvalItem = NSMenuItem(title: "Allow in Login Items…", action: nil, keyEquivalent: "")
    private let service = SMAppService.mainApp
    private var changing = false

    override init() {
        super.init()
        menuItem.target = self
        menuItem.action = #selector(toggle)
        approvalItem.target = self
        approvalItem.action = #selector(openSettings)
        refresh()
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unavailable"
        }
    }

    func configureOnFirstLaunch(defaults: UserDefaults = .standard) {
        // This records a one-time installation step, not the login preference.
        // Once attempted, later launches respect the user's choice in Settings.
        let key = "openAtLoginInitialSetupAttempted"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        setEnabled(true)
    }

    func refresh() {
        let status = service.status
        menuItem.isEnabled = !changing
        approvalItem.isHidden = status != .requiresApproval
        approvalItem.isEnabled = !changing
        switch status {
        case .enabled:
            menuItem.state = .on
            menuItem.toolTip = "Headroom opens when you log in to this Mac."
        case .requiresApproval:
            menuItem.state = .mixed
            menuItem.toolTip = "Allow Headroom in macOS Login Items to finish enabling this setting."
        case .notRegistered, .notFound:
            menuItem.state = .off
            menuItem.toolTip = "Open Headroom automatically when you log in to this Mac."
        @unknown default:
            menuItem.state = .off
            menuItem.isEnabled = false
            menuItem.toolTip = "macOS could not determine the login setting."
        }
    }

    @objc private func toggle() {
        let current = service.status
        setEnabled(current != .enabled && current != .requiresApproval)
    }

    func setEnabled(_ enabled: Bool) {
        guard !changing else { return }
        let current = service.status
        // A pending request must be approved in Settings, not registered again.
        if enabled && (current == .enabled || current == .requiresApproval) { refresh(); return }
        if !enabled && (current == .notRegistered || current == .notFound) { refresh(); return }
        changing = true
        refresh()
        Task { @MainActor in
            defer { changing = false; refresh() }
            do {
                if enabled { try service.register() }
                else { try await service.unregister() }
            } catch {
                let latest = service.status
                // Settings may have completed the requested change concurrently.
                if enabled && (latest == .enabled || latest == .requiresApproval) { return }
                if !enabled && (latest == .notRegistered || latest == .notFound) { return }
                let alert = NSAlert()
                alert.messageText = "Couldn’t change Open at Login"
                alert.informativeText = "Keep Headroom in Applications and try again.\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Login Settings…")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn { SMAppService.openSystemSettingsLoginItems() }
            }
        }
    }

    @objc private func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
