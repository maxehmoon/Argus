import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let preferences = WidgetPreferences()
  private var menuBarController: MenuBarController?
  private var settingsWindowController: SettingsWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    installApplicationMenu()

    let controller = MenuBarController(
      preferences: preferences,
      showSettings: { [weak self] in
        self?.showSettings()
      }
    )
    menuBarController = controller
    controller.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    menuBarController?.stop()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    showSettings()
    return true
  }

  private func installApplicationMenu() {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(showSettings),
      keyEquivalent: ","
    )
    settingsItem.target = self
    applicationMenu.addItem(settingsItem)
    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)
    NSApp.mainMenu = mainMenu
  }

  @objc
  private func showSettings() {
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        preferences: preferences
      )
    }
    settingsWindowController?.present()
  }
}
