import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
  init(
    preferences: WidgetPreferences,
    checkForUpdates: @escaping @MainActor () -> Void
  ) {
    let tabs = SettingsTabViewController(
      preferences: preferences,
      checkForUpdates: checkForUpdates
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: SettingsLayout.contentSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Argus Settings"
    window.toolbarStyle = .preference
    window.contentViewController = tabs
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.collectionBehavior = [.moveToActiveSpace]
    let restoredFrame = window.setFrameUsingName("ArgusSettingsWindow", force: true)
    window.setContentSize(SettingsLayout.contentSize)
    if !restoredFrame {
      window.center()
    }

    super.init(window: window)
    shouldCascadeWindows = false
    window.setFrameAutosaveName("ArgusSettingsWindow")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

private enum SettingsLayout {
  static let contentSize = NSSize(width: 560, height: 380)
}

private enum SettingsPage: String {
  case general
  case widgets
  case network
  case about

  var title: String {
    switch self {
    case .general: "General"
    case .widgets: "Menu Bar"
    case .network: "Network"
    case .about: "About"
    }
  }

  var symbolName: String {
    switch self {
    case .general: "gearshape"
    case .widgets: "menubar.rectangle"
    case .network: "network"
    case .about: "info.circle"
    }
  }
}

@MainActor
private final class SettingsTabViewController: NSTabViewController {
  init(preferences: WidgetPreferences, checkForUpdates: @escaping @MainActor () -> Void) {
    let savedPage = UserDefaults.standard.string(forKey: "settings.selectedPage")
    super.init(nibName: nil, bundle: nil)
    tabStyle = .toolbar
    transitionOptions = []
    canPropagateSelectedChildViewControllerTitle = false

    addPane(.general, content: GeneralSettingsPage(preferences: preferences))
    addPane(.widgets, content: WidgetsSettingsPage(preferences: preferences))
    addPane(.network, content: NetworkSettingsPage(preferences: preferences))
    addPane(.about, content: AboutSettingsPage(checkForUpdates: checkForUpdates))
    selectedTabViewItemIndex =
      tabViewItems.firstIndex { $0.identifier as? String == savedPage } ?? 0
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func addPane<Content: View>(_ page: SettingsPage, content: Content) {
    let controller = NSHostingController(
      rootView:
        content
        .padding(28)
        .frame(width: SettingsLayout.contentSize.width, height: SettingsLayout.contentSize.height)
    )
    controller.title = page.title
    let item = NSTabViewItem(viewController: controller)
    item.identifier = page.rawValue
    item.label = page.title
    item.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
    addTabViewItem(item)
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    view.window?.toolbar?.allowsUserCustomization = false
    view.window?.toolbar?.displayMode = .iconAndLabel
  }

  override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace] + super.toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace]
  }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    if let page = tabViewItem?.identifier as? String {
      UserDefaults.standard.set(page, forKey: "settings.selectedPage")
    }
  }
}

@MainActor
private struct WidgetsSettingsPage: View {
  @ObservedObject var preferences: WidgetPreferences

  var body: some View {
    Form {
      LabeledContent("Show in menu bar:") {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(WidgetKind.allCases) { widget in
            WidgetToggleRow(widget: widget, preferences: preferences)
          }
          Text("Keep at least one widget enabled.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.columns)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

@MainActor
private struct WidgetToggleRow: View {
  let widget: WidgetKind
  @ObservedObject var preferences: WidgetPreferences

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Toggle(widget.title, isOn: binding)
        .toggleStyle(.checkbox)
        .disabled(
          (!widget.isAvailable && !preferences.isEnabled(widget))
            || !preferences.canDisable(widget)
        )
        .help(widget.description)
      Text(widget.isAvailable ? widget.description : "No internal battery on this Mac.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 20)
    }
  }

  private var binding: Binding<Bool> {
    Binding(
      get: { preferences.isEnabled(widget) },
      set: { preferences.setEnabled($0, for: widget) }
    )
  }
}

@MainActor
private struct GeneralSettingsPage: View {
  @ObservedObject var preferences: WidgetPreferences

  var body: some View {
    Form {
      StartAtLoginSettingsRow()

      LabeledContent("Refresh interval:") {
        VStack(alignment: .leading, spacing: 6) {
          Picker("Refresh interval", selection: refreshRateBinding) {
            ForEach(RefreshRate.allCases) { rate in
              Text(rate.title).tag(rate)
            }
          }
          .labelsHidden()
          .frame(width: 170, alignment: .leading)
          Text("Less frequent updates reduce background activity.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
      }

      LabeledContent("Graph history:") {
        Picker("Graph history", selection: graphPeriodBinding) {
          ForEach(GraphPeriod.allCases) { period in
            Text(period.title).tag(period)
          }
        }
        .labelsHidden()
        .frame(width: 170, alignment: .leading)
      }

      LabeledContent("Appearance:") {
        VStack(alignment: .leading, spacing: 6) {
          Toggle("Animate changes in panels", isOn: animateChangesBinding)
            .toggleStyle(.checkbox)
          Text("Animations also follow the macOS Reduce Motion setting.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
      }
    }
    .formStyle(.columns)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var refreshRateBinding: Binding<RefreshRate> {
    Binding(
      get: { preferences.refreshRate },
      set: { preferences.setRefreshRate($0) }
    )
  }

  private var animateChangesBinding: Binding<Bool> {
    Binding(
      get: { preferences.animateChanges },
      set: { preferences.setAnimateChanges($0) }
    )
  }

  private var graphPeriodBinding: Binding<GraphPeriod> {
    Binding(
      get: { preferences.graphPeriod },
      set: { preferences.setGraphPeriod($0) }
    )
  }
}

@MainActor
private struct NetworkSettingsPage: View {
  @ObservedObject var preferences: WidgetPreferences

  var body: some View {
    Form {
      LabeledContent("Public IP:") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Show IP address and country",
            isOn: Binding(
              get: { preferences.showPublicIP },
              set: { preferences.setShowPublicIP($0) }
            )
          )
          .toggleStyle(.checkbox)
          Text("Uses ipwho.is, with country.is and ipify.org as fallbacks.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
      }
      .accessibilityElement(children: .contain)
      WiFiNameSettingsRow()
    }
    .formStyle(.columns)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

@MainActor
private struct StartAtLoginSettingsRow: View {
  @State private var status: SMAppService.Status = .notRegistered
  @State private var errorMessage: String?

  var body: some View {
    LabeledContent("Startup:") {
      VStack(alignment: .leading, spacing: 8) {
        Toggle(
          "Start Argus at login",
          isOn: Binding(
            get: { status == .enabled },
            set: { setEnabled($0) }
          )
        )
        .toggleStyle(.checkbox)

        if status == .requiresApproval {
          Text("Allow Argus in Login Items to start automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Open Login Items Settings…") {
            SMAppService.openSystemSettingsLoginItems()
          }
        }
        if let errorMessage {
          Text("Couldn’t update start at login: \(errorMessage)")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onAppear { refreshStatus() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refreshStatus()
    }
  }

  private func refreshStatus() {
    status = SMAppService.mainApp.status
  }

  private func setEnabled(_ enabled: Bool) {
    let service = SMAppService.mainApp
    errorMessage = nil
    defer { refreshStatus() }

    do {
      if enabled {
        if service.status == .requiresApproval {
          SMAppService.openSystemSettingsLoginItems()
        } else if service.status != .enabled {
          try service.register()
        }
      } else if service.status == .enabled || service.status == .requiresApproval {
        try service.unregister()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
private struct AboutSettingsPage: View {
  let checkForUpdates: @MainActor () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 72, height: 72)

      Text("Argus")
        .font(.title2.weight(.semibold))
      Text(applicationVersion)
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("A lightweight system monitor for your menu bar.")
        .foregroundStyle(.secondary)
        .padding(.top, 6)

      Button("Check for Updates…", action: checkForUpdates)
        .padding(.top, 10)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private var applicationVersion: String {
  let version =
    Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "1.0.0"
  return "Version \(version)"
}
