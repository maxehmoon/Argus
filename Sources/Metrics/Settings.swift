import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
  init(preferences: WidgetPreferences) {
    let hostingController = NSHostingController(
      rootView: SettingsRootView(preferences: preferences)
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Argus Settings"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.contentViewController = hostingController
    window.minSize = NSSize(width: 600, height: 420)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false
    if !window.setFrameUsingName("ArgusSettingsWindowMinimal") {
      window.center()
    }

    super.init(window: window)
    shouldCascadeWindows = false
    window.setFrameAutosaveName("ArgusSettingsWindowMinimal")
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

private enum SettingsPage: String, CaseIterable, Identifiable {
  case widgets
  case general
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .widgets: "Widgets"
    case .general: "General"
    case .about: "About"
    }
  }

  var symbolName: String {
    switch self {
    case .widgets: "rectangle.3.group"
    case .general: "gearshape"
    case .about: "info.circle"
    }
  }
}

@MainActor
private struct SettingsRootView: View {
  @ObservedObject var preferences: WidgetPreferences
  @AppStorage("settings.selectedPage") private var selectedPage =
    SettingsPage.widgets.rawValue

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        SettingsSidebarHeader()

        List(SettingsPage.allCases, selection: $selectedPage) { page in
          SettingsSidebarRow(page: page)
            .tag(page.rawValue)
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 30)
      }
      .navigationTitle("Argus")
      .navigationSplitViewColumnWidth(min: 164, ideal: 176, max: 190)
    } detail: {
      VStack(alignment: .leading, spacing: 0) {
        Text(currentPage.title)
          .font(.title2.weight(.semibold))
          .padding(.horizontal, 20)
          .padding(.top, 18)
          .padding(.bottom, 8)

        detail
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 600, minHeight: 420)
  }

  private var currentPage: SettingsPage {
    SettingsPage(rawValue: selectedPage) ?? .widgets
  }

  @ViewBuilder
  private var detail: some View {
    switch currentPage {
    case .widgets:
      WidgetsSettingsPage(preferences: preferences)
    case .general:
      GeneralSettingsPage(preferences: preferences)
    case .about:
      AboutSettingsPage()
    }
  }
}

@MainActor
private struct SettingsSidebarHeader: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 30, height: 30)

      VStack(alignment: .leading, spacing: 1) {
        Text("Argus")
          .font(.headline)
        Text(applicationVersion)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .accessibilityElement(children: .combine)
  }
}

private struct SettingsSidebarRow: View {
  let page: SettingsPage

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: page.symbolName)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(width: 18)

      Text(page.title)
    }
    .contentShape(Rectangle())
  }
}

@MainActor
private struct WidgetsSettingsPage: View {
  @ObservedObject var preferences: WidgetPreferences

  var body: some View {
    Form {
      Section {
        ForEach(WidgetKind.allCases) { widget in
          WidgetToggleRow(widget: widget, preferences: preferences)
        }
      }
    }
    .formStyle(.grouped)
  }
}

@MainActor
private struct WidgetToggleRow: View {
  let widget: WidgetKind
  @ObservedObject var preferences: WidgetPreferences

  var body: some View {
    Toggle(isOn: binding) {
      HStack(spacing: 11) {
        Image(systemName: widget.symbolName)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 24)

        Text(widget.title)
      }
      .padding(.vertical, 3)
    }
    .toggleStyle(.switch)
    .disabled(
      (!widget.isAvailable && !preferences.isEnabled(widget))
        || !preferences.canDisable(widget)
    )
    .accessibilityHint(widget.description)
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
      Section {
        Picker("Background refresh", selection: refreshRateBinding) {
          ForEach(RefreshRate.allCases) { rate in
            Text(rate.title).tag(rate)
          }
        }

        Picker("Graph history", selection: graphPeriodBinding) {
          ForEach(GraphPeriod.allCases) { period in
            Text(period.title).tag(period)
          }
        }
      } header: {
        Text("Updates")
      }

      Section {
        Toggle("Animate popup changes", isOn: animateChangesBinding)
          .toggleStyle(.switch)
      } header: {
        Text("Motion")
      }

      Section {
        Toggle("Show public IP and country", isOn: showPublicIPBinding)
          .toggleStyle(.switch)
      } header: {
        Text("Network")
      } footer: {
        Text(
          "When enabled, Argus contacts ipwho.is. country.is and ipify.org are used as fallbacks."
        )
      }
    }
    .formStyle(.grouped)
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

  private var showPublicIPBinding: Binding<Bool> {
    Binding(
      get: { preferences.showPublicIP },
      set: { preferences.setShowPublicIP($0) }
    )
  }
}

@MainActor
private struct AboutSettingsPage: View {
  var body: some View {
    VStack(spacing: 14) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 80, height: 80)

      Text("Argus")
        .font(.title2.weight(.semibold))
      Text(applicationVersion)
        .foregroundStyle(.secondary)
      Text("Native. Lightweight. Built for macOS.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 70)
  }
}

private var applicationVersion: String {
  let version =
    Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "1.0.0"
  return "Version \(version)"
}
