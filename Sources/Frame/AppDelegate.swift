import AppKit
import FrameCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Started at login (or brought back quietly by an update): the icon appears and nothing opens.
    private var startedQuietly = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The family's dark look everywhere: the panel, Settings, menus and the About panel.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        startedQuietly = Updater.LoginItem.launchedAtLogin
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        StatusItem.shared.install()
        Updates.start()
        AppActions.didFinishLaunching()
        if SettingsWindow.reopensAfterRestart() {
            // Back from the restart for a new interface language.
            SettingsWindow.show()
        } else if !startedQuietly {
            // Opened by hand: the panel shows where the app lives, once the icon has its place in the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { StatusItem.shared.showPanel() }
        }
    }

    /// A recording in progress is saved before the app quits (`AppActions.shouldTerminate`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppActions.shouldTerminate()
    }

    /// Opening the app again (from Finder, Spotlight, Launchpad) while it runs opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StatusItem.shared.showPanel()
        return true
    }

    // MARK: Actions of the menus (the menu of the icon and the invisible main menu)

    @objc func showSettings(_ sender: Any?) {
        SettingsWindow.show()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updates.checkFromMenu()
    }

    /// The standard About panel: the name, the version and the copyright from Info.plist.
    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
