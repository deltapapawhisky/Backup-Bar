import SwiftUI

@main
struct BackupBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var timeMachineService: TimeMachineService?
    private var notificationManager: NotificationManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager = NotificationManager()
        notificationManager?.requestAuthorization()

        timeMachineService = TimeMachineService()
        statusBarController = StatusBarController(
            timeMachineService: timeMachineService!,
            notificationManager: notificationManager!
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        timeMachineService?.stopMonitoring()
    }
}
