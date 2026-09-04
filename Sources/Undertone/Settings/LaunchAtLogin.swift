import Foundation
import ServiceManagement

/// Login item via SMAppService. Only meaningful when running from a signed .app bundle (ideally in /Applications).
enum LaunchAtLogin {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static var isInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static var status: SMAppService.Status {
        isAvailable ? SMAppService.mainApp.status : .notFound
    }

    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
