import Combine
import Foundation
import MetricsCore

enum WidgetKind: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case network
  case storage
  case battery

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .network: "Network"
    case .storage: "Storage"
    case .battery: "Battery"
    }
  }

  var symbolName: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .network: "arrow.up.arrow.down"
    case .storage: "internaldrive"
    case .battery: "battery.100percent"
    }
  }

  var description: String {
    switch self {
    case .cpu:
      "Overall processor usage and the busiest applications."
    case .memory:
      "Memory usage and the applications using the most RAM."
    case .network:
      "Received and sent traffic with the most active applications."
    case .storage:
      "System-volume capacity, all-disk activity, and the busiest applications."
    case .battery:
      "Charge level, power state, and estimated time remaining."
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .cpu: "CPU usage"
    case .memory: "Memory usage"
    case .network: "Network throughput"
    case .storage: "Storage usage"
    case .battery: "Battery charge"
    }
  }

  var sectionTitle: String {
    switch self {
    case .cpu, .memory, .network, .storage: "Top Applications"
    case .battery: "Top Energy Users"
    }
  }

  var loadingTitle: String {
    switch self {
    case .cpu: "Measuring live CPU…"
    case .memory: "Finding memory-heavy apps…"
    case .network: "Measuring one second of traffic…"
    case .storage: "Measuring one second of disk activity…"
    default: "Loading…"
    }
  }

  var summaryTitle: String {
    self == .storage ? "All Disk Activity" : title
  }

  var sampleOption: SystemSampleOptions {
    switch self {
    case .cpu: .cpu
    case .memory: .memory
    case .network: .network
    case .storage: .storage
    case .battery: .battery
    }
  }

  var defaultEnabled: Bool {
    self == .cpu || self == .memory || self == .network
  }

  var isAvailable: Bool {
    self != .battery || SystemCapabilities.hasBattery
  }

  fileprivate var preferenceKey: String {
    "widgets.\(rawValue).enabled"
  }
}

enum RefreshRate: Int, CaseIterable, Identifiable, Sendable {
  case everySecond = 1
  case balanced = 2
  case efficient = 5

  var id: Int { rawValue }
  var interval: TimeInterval { TimeInterval(rawValue) }

  var title: String {
    switch self {
    case .everySecond: "Every second"
    case .balanced: "Every 2 seconds"
    case .efficient: "Every 5 seconds"
    }
  }
}

enum GraphPeriod: Int, CaseIterable, Identifiable, Sendable {
  case thirtySeconds = 30
  case oneMinute = 60
  case threeMinutes = 180
  case fiveMinutes = 300

  var id: Int { rawValue }
  var interval: TimeInterval { TimeInterval(rawValue) }
  var duration: Duration { .seconds(rawValue) }

  var title: String {
    switch self {
    case .thirtySeconds: "30 seconds"
    case .oneMinute: "1 minute"
    case .threeMinutes: "3 minutes"
    case .fiveMinutes: "5 minutes"
    }
  }

  var historyTitle: String {
    "Last \(title.capitalized)"
  }

  static var maximumDuration: Duration {
    .seconds(Self.allCases.map(\.rawValue).max() ?? fiveMinutes.rawValue)
  }
}

@MainActor
final class WidgetPreferences: ObservableObject {
  private enum Key {
    static let refreshRate = "general.refreshRate"
    static let graphPeriod = "general.graphPeriod"
    static let animateChanges = "general.animateChanges"
    static let showPublicIP = "network.showPublicIP"
  }

  private static let legacyBundleIdentifier = "com.metrics.menubar"

  @Published private(set) var enabledWidgets: Set<WidgetKind>
  @Published private(set) var refreshRate: RefreshRate
  @Published private(set) var graphPeriod: GraphPeriod
  @Published private(set) var animateChanges: Bool
  @Published private(set) var showPublicIP: Bool

  var onEnabledWidgetsChange: ((Set<WidgetKind>) -> Void)?
  var onRefreshRateChange: ((RefreshRate) -> Void)?
  var onGraphPeriodChange: ((GraphPeriod) -> Void)?
  var onShowPublicIPChange: ((Bool) -> Void)?

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    Self.migrateLegacyPreferences(into: defaults)
    let enabled = WidgetKind.allCases.filter { widget in
      guard widget.isAvailable else { return false }
      guard let stored = defaults.object(forKey: widget.preferenceKey) as? Bool else {
        return widget.defaultEnabled
      }
      return stored
    }
    enabledWidgets = Set(enabled.isEmpty ? [.cpu] : enabled)

    let storedRate = defaults.integer(forKey: Key.refreshRate)
    refreshRate = RefreshRate(rawValue: storedRate) ?? .balanced
    let storedGraphPeriod = defaults.integer(forKey: Key.graphPeriod)
    graphPeriod = GraphPeriod(rawValue: storedGraphPeriod) ?? .threeMinutes
    if defaults.object(forKey: Key.animateChanges) == nil {
      animateChanges = true
    } else {
      animateChanges = defaults.bool(forKey: Key.animateChanges)
    }
    if defaults.object(forKey: Key.showPublicIP) == nil {
      showPublicIP = true
    } else {
      showPublicIP = defaults.bool(forKey: Key.showPublicIP)
    }
  }

  func isEnabled(_ widget: WidgetKind) -> Bool {
    enabledWidgets.contains(widget)
  }

  func canDisable(_ widget: WidgetKind) -> Bool {
    !isEnabled(widget) || enabledWidgets.count > 1
  }

  func setEnabled(_ enabled: Bool, for widget: WidgetKind) {
    guard !enabled || widget.isAvailable else { return }
    guard enabled != isEnabled(widget) else { return }
    guard enabled || enabledWidgets.count > 1 else { return }

    if enabled {
      enabledWidgets.insert(widget)
    } else {
      enabledWidgets.remove(widget)
    }
    defaults.set(enabled, forKey: widget.preferenceKey)
    onEnabledWidgetsChange?(enabledWidgets)
  }

  func setRefreshRate(_ refreshRate: RefreshRate) {
    guard self.refreshRate != refreshRate else { return }
    self.refreshRate = refreshRate
    defaults.set(refreshRate.rawValue, forKey: Key.refreshRate)
    onRefreshRateChange?(refreshRate)
  }

  func setGraphPeriod(_ graphPeriod: GraphPeriod) {
    guard self.graphPeriod != graphPeriod else { return }
    self.graphPeriod = graphPeriod
    defaults.set(graphPeriod.rawValue, forKey: Key.graphPeriod)
    onGraphPeriodChange?(graphPeriod)
  }

  func setAnimateChanges(_ animateChanges: Bool) {
    guard self.animateChanges != animateChanges else { return }
    self.animateChanges = animateChanges
    defaults.set(animateChanges, forKey: Key.animateChanges)
  }

  func setShowPublicIP(_ showPublicIP: Bool) {
    guard self.showPublicIP != showPublicIP else { return }
    self.showPublicIP = showPublicIP
    defaults.set(showPublicIP, forKey: Key.showPublicIP)
    onShowPublicIPChange?(showPublicIP)
  }

  private static func migrateLegacyPreferences(into defaults: UserDefaults) {
    guard
      defaults === UserDefaults.standard,
      Bundle.main.bundleIdentifier == "com.maxmoon.argus",
      let legacyValues = defaults.persistentDomain(
        forName: legacyBundleIdentifier
      )
    else { return }

    let keys = [
      Key.refreshRate,
      Key.graphPeriod,
      Key.animateChanges,
      "settings.selectedPage",
      "NSWindow Frame ArgusSettingsWindowMinimal",
    ] + WidgetKind.allCases.map(\.preferenceKey)

    for key in keys where defaults.object(forKey: key) == nil {
      if let value = legacyValues[key] {
        defaults.set(value, forKey: key)
      }
    }
  }
}
