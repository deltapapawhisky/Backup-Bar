import Foundation
import ServiceManagement

enum LaunchAtLogin {
    private static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.timemachinemonitor.app"

    static var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            } else {
                return UserDefaults.standard.bool(forKey: "launchAtLogin")
            }
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)")
                }
            } else {
                UserDefaults.standard.set(newValue, forKey: "launchAtLogin")
            }
        }
    }
}
