import AppKit
import ServiceManagement

final class LoginItemController: NSObject, NSMenuItemValidation {
    private let promptPreference = "hasAskedToOpenAtLogin"

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        item.target = self
        return item
    }

    func promptOnFirstLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: promptPreference) else { return }
        if SMAppService.mainApp.status == .enabled {
            UserDefaults.standard.set(true, forKey: promptPreference)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Open ClipEdge when you log in?"
        alert.informativeText = "Add ClipEdge to your login items so your clipboard history is ready when you need it. You can change this later using Open at Login in the ClipEdge menu."
        alert.addButton(withTitle: "Add to Login Items")
        alert.addButton(withTitle: "Not Now")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: promptPreference)
        if response == .alertFirstButtonReturn {
            enableLoginItem()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled:
            menuItem.title = "Open at Login"
            menuItem.state = .on
        case .requiresApproval:
            menuItem.title = "Open at Login (Approval Needed)"
            menuItem.state = .mixed
        default:
            menuItem.title = "Open at Login"
            menuItem.state = .off
        }
        return true
    }

    @objc private func toggleLoginItem() {
        // A menu choice is also an explicit decision; don't ask again next launch.
        UserDefaults.standard.set(true, forKey: promptPreference)
        switch SMAppService.mainApp.status {
        case .enabled:
            disableLoginItem()
        case .requiresApproval:
            showApprovalNeeded()
        default:
            enableLoginItem()
        }
    }

    private func enableLoginItem() {
        if SMAppService.mainApp.status == .requiresApproval {
            showApprovalNeeded()
            return
        }
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                showApprovalNeeded()
            }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                showApprovalNeeded()
            } else {
                showError(error, action: "add ClipEdge to your login items")
            }
        }
    }

    private func disableLoginItem() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            showError(error, action: "remove ClipEdge from your login items")
        }
    }

    private func showApprovalNeeded() {
        let alert = NSAlert()
        alert.messageText = "Allow ClipEdge in Login Items"
        alert.informativeText = "macOS needs your approval before ClipEdge can open when you log in. Enable ClipEdge in System Settings, or remove it from your login items."
        alert.addButton(withTitle: "Open Login Items Settings")
        alert.addButton(withTitle: "Remove Login Item")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SMAppService.openSystemSettingsLoginItems()
        case .alertSecondButtonReturn:
            disableLoginItem()
        default:
            break
        }
    }

    private func showError(_ error: Error, action: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClipEdge couldn't update Login Items"
        alert.informativeText = "macOS couldn't \(action). \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Login Items Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
