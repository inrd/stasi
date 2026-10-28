import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sleepObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app launched")
        RecorderModel.shared.bootstrap()

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                RecorderModel.shared.systemWillSleep()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = RecorderModel.shared
        guard model.needsFinalize else { return .terminateNow }

        Log.info("quit requested while busy; finalizing first")
        model.finalizeBeforeQuit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        Log.info("app terminated")
    }
}
