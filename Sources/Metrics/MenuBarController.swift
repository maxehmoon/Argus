import AppKit
import IOKit.ps
import MetricsCore
import Network

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
  private static let applicationLimit = 15
  private static let minimumHistoryInterval = Duration.milliseconds(750)

  private struct HistoryPoint {
    let capturedAt: ContinuousClock.Instant
    let primary: Double
    let secondary: Double?
  }

  private struct MenuPresentation {
    let menu: NSMenu
    let summary: ResourceSummaryView
    let historySection: MenuSectionHeaderView?
    let history: ResourceHistoryView?
    let detailsSection: MenuSectionHeaderView?
    let detailsList: InlineMetricsView?
    let section: MenuSectionHeaderView
    let list: ResourceListView
    let storageCapacity: StorageCapacityView?
  }

  private let sampler = SystemStatsSampler()
  private let processSampler = ProcessStatsSampler()
  private let networkProcessSampler = NetworkProcessSampler()
  private let cpuHardwareSampler = CPUHardwareSampler()
  private let publicIPLookup = PublicIPLookup()
  private let preferences: WidgetPreferences
  private let showSettings: @MainActor () -> Void

  private var timer: Timer?
  private var powerSourceRunLoopSource: CFRunLoopSource?
  private var networkPathMonitor: NWPathMonitor?
  private let networkMonitorQueue = DispatchQueue(
    label: "com.maxmoon.argus.network-monitor",
    qos: .utility
  )
  private var statusItems: [WidgetKind: NSStatusItem] = [:]
  private var presentations: [WidgetKind: MenuPresentation] = [:]
  private var menuKinds: [ObjectIdentifier: WidgetKind] = [:]
  private var detailTasks: [WidgetKind: Task<Void, Never>] = [:]
  private var publicIPLookupTask: Task<Void, Never>?
  private var detailGenerations: [WidgetKind: UInt] = [:]
  private var openMenus: Set<WidgetKind> = []
  private var historyPoints: [WidgetKind: [HistoryPoint]] = [:]
  private var iconCache: [String: NSImage] = [:]
  private var batteryStatusSymbolName: String?
  private var networkStatusView: NetworkStatusView?
  private var cpuHardwareStats: CPUHardwareStats?
  private var latestSnapshot: StatsSnapshot?
  private var sampleOptions: SystemSampleOptions = []
  private var consecutiveHighCPUSamples = 0
  private var isCPUHighlighted = false
  private var publicIPValue = "Checking…"
  private var publicIPAddress: String?
  private var receivedInitialNetworkPath = false

  init(
    preferences: WidgetPreferences,
    showSettings: @escaping @MainActor () -> Void
  ) {
    self.preferences = preferences
    self.showSettings = showSettings
    super.init()
  }

  func start() {
    guard statusItems.isEmpty else { return }

    for kind in WidgetKind.allCases where preferences.isEnabled(kind) {
      statusItems[kind] = makeStatusItem(for: kind)
    }
    reconcileWidgetVisibility()
    startPowerSourceMonitoring()
    startNetworkMonitoring()

    // Seed rate counters once. The first visible sample arrives one second later.
    _ = sampler.sample(options: sampleOptions)

    preferences.onEnabledWidgetsChange = { [weak self] _ in
      self?.reconcileWidgetVisibility()
      self?.refresh()
    }
    preferences.onRefreshRateChange = { [weak self] _ in
      self?.startTimer()
    }
    preferences.onGraphPeriodChange = { [weak self] _ in
      self?.graphPeriodDidChange()
    }
    preferences.onShowPublicIPChange = { [weak self] isEnabled in
      self?.publicIPPreferenceDidChange(isEnabled)
    }
    startTimer()
  }

  private func startTimer() {
    timer?.invalidate()
    let timer = Timer(
      fireAt: Date(timeIntervalSinceNow: 1),
      interval: preferences.refreshRate.interval,
      target: self,
      selector: #selector(refresh),
      userInfo: nil,
      repeats: true
    )
    timer.tolerance = min(0.5, preferences.refreshRate.interval * 0.15)
    // A status menu presents in event-tracking mode. Keeping this timer in the
    // default mode avoids relaying out menu-bar items beneath an open menu.
    RunLoop.main.add(timer, forMode: .default)
    self.timer = timer
  }

  private func reconcileWidgetVisibility() {
    sampleOptions = preferences.enabledWidgets.reduce(into: []) { options, widget in
      options.insert(widget.sampleOption)
    }

    for kind in WidgetKind.allCases {
      let isEnabled = preferences.isEnabled(kind)
      if isEnabled {
        if statusItems[kind] == nil {
          statusItems[kind] = makeStatusItem(for: kind)
        }
        continue
      }

      if openMenus.remove(kind) != nil {
        presentations[kind]?.menu.cancelTracking()
      }
      detailGenerations[kind, default: 0] &+= 1
      detailTasks.removeValue(forKey: kind)?.cancel()
      historyPoints.removeValue(forKey: kind)
      if kind == .cpu {
        consecutiveHighCPUSamples = 0
        isCPUHighlighted = false
      }
      removeStatusItem(for: kind)
    }
  }

  private func removeStatusItem(for kind: WidgetKind) {
    if let presentation = presentations.removeValue(forKey: kind) {
      menuKinds.removeValue(forKey: ObjectIdentifier(presentation.menu))
    }
    if let item = statusItems.removeValue(forKey: kind) {
      NSStatusBar.system.removeStatusItem(item)
    }
    if kind == .network {
      networkStatusView = nil
    } else if kind == .battery {
      batteryStatusSymbolName = nil
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    stopPowerSourceMonitoring()
    stopNetworkMonitoring()
    preferences.onEnabledWidgetsChange = nil
    preferences.onRefreshRateChange = nil
    preferences.onGraphPeriodChange = nil
    preferences.onShowPublicIPChange = nil

    for task in detailTasks.values {
      task.cancel()
    }
    publicIPLookupTask?.cancel()
    publicIPLookupTask = nil
    detailTasks.removeAll(keepingCapacity: false)
    detailGenerations.removeAll(keepingCapacity: false)

    for item in statusItems.values {
      NSStatusBar.system.removeStatusItem(item)
    }
    statusItems.removeAll(keepingCapacity: false)
    presentations.removeAll(keepingCapacity: false)
    menuKinds.removeAll(keepingCapacity: false)
    openMenus.removeAll(keepingCapacity: false)
    historyPoints.removeAll(keepingCapacity: false)
    iconCache.removeAll(keepingCapacity: false)
    networkStatusView = nil
    latestSnapshot = nil
    consecutiveHighCPUSamples = 0
    isCPUHighlighted = false
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard
      let kind = menuKinds[ObjectIdentifier(menu)],
      let presentation = presentations[kind]
    else { return }
    openMenus.insert(kind)
    updateHistoryView(for: kind)
    presentation.history?.setAnimationActive(preferences.animateChanges)
    presentation.summary.setAnimationsActive(preferences.animateChanges)
    presentation.detailsList?.setLoadingEffectsActive(true)
    presentation.list.setAnimationsActive(preferences.animateChanges)
    if kind == .cpu {
      cpuHardwareStats = nil
    }
    sampleSystemStats(
      forOpenMenu: kind,
      preserveLatestNetworkRates: true
    )
    showLoading(for: kind)
    if kind == .network, preferences.showPublicIP {
      refreshPublicIP()
    }
    loadApplicationDetails(for: kind)
  }

  func menuDidClose(_ menu: NSMenu) {
    guard let kind = menuKinds[ObjectIdentifier(menu)] else { return }
    openMenus.remove(kind)
    presentations[kind]?.history?.setAnimationActive(false)
    presentations[kind]?.summary.setAnimationsActive(false)
    presentations[kind]?.detailsList?.setLoadingEffectsActive(false)
    presentations[kind]?.list.setAnimationsActive(false)
    detailGenerations[kind, default: 0] &+= 1
    detailTasks.removeValue(forKey: kind)?.cancel()
  }

  @objc
  private func refresh() {
    autoreleasepool {
      applySystemSnapshot(sampler.sample(options: sampleOptions))
    }
  }

  private func makeStatusItem(for kind: WidgetKind) -> NSStatusItem {
    let length =
      kind == .network
      ? NetworkStatusView.preferredWidth
      : NSStatusItem.variableLength
    let item = NSStatusBar.system.statusItem(withLength: length)
    guard let button = item.button else { return item }

    if kind == .network {
      button.image = nil
      button.title = ""

      let statusView = NetworkStatusView(frame: button.bounds)
      statusView.autoresizingMask = [.width, .height]
      button.addSubview(statusView)
      networkStatusView = statusView
    } else {
      let image = NSImage(
        systemSymbolName: kind.symbolName,
        accessibilityDescription: kind.accessibilityLabel
      )
      image?.isTemplate = true
      button.image = image
      button.imagePosition = .imageLeading
      button.font = .monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
      )
      button.title = "…"
    }
    button.toolTip = kind.accessibilityLabel
    button.setAccessibilityLabel(kind.accessibilityLabel)

    let presentation = makeDetailMenu(for: kind)
    presentations[kind] = presentation
    menuKinds[ObjectIdentifier(presentation.menu)] = kind
    item.menu = presentation.menu
    return item
  }

  private func makeDetailMenu(for kind: WidgetKind) -> MenuPresentation {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self

    let valueLabels: (primary: String, secondary: String)? =
      switch kind {
      case .network: (primary: "Received", secondary: "Sent")
      case .storage: (primary: "Read", secondary: "Write")
      default: nil
      }
    let summary = ResourceSummaryView(
      symbolName: kind.symbolName,
      title: kind.summaryTitle,
      primary: "–",
      secondary: valueLabels == nil ? "" : "–",
      valueLabels: valueLabels
    )
    menu.addItem(viewItem(summary))

    let historySection: MenuSectionHeaderView?
    let history: ResourceHistoryView?
    if kind != .battery {
      let historyInterval = preferences.graphPeriod.interval
      let historyTitle = preferences.graphPeriod.historyTitle
      let view =
        switch kind {
        case .cpu:
          ResourceHistoryView(
            primaryColor: .systemBlue,
            fixedMaximum: 100,
            valueStyle: .percentage,
            historyInterval: historyInterval,
            accessibilityLabel: historyTitle
          )
        case .memory:
          ResourceHistoryView(
            primaryColor: .systemPurple,
            fixedMaximum: 100,
            valueStyle: .percentage,
            historyInterval: historyInterval,
            accessibilityLabel: historyTitle
          )
        case .network:
          ResourceHistoryView(
            primaryColor: .systemBlue,
            secondaryColor: .systemOrange,
            valueStyle: .rate(primaryLabel: "↓", secondaryLabel: "↑"),
            historyInterval: historyInterval,
            accessibilityLabel: historyTitle
          )
        case .storage:
          ResourceHistoryView(
            primaryColor: .systemBlue,
            secondaryColor: .systemOrange,
            valueStyle: .rate(primaryLabel: "Read", secondaryLabel: "Write"),
            historyInterval: historyInterval,
            accessibilityLabel: historyTitle
          )
        default:
          ResourceHistoryView(
            primaryColor: .systemBlue,
            valueStyle: .percentage,
            historyInterval: historyInterval,
            accessibilityLabel: historyTitle
          )
        }
      let section = MenuSectionHeaderView(title: historyTitle)
      menu.addItem(viewItem(section))
      menu.addItem(viewItem(view))
      historySection = section
      history = view
    } else {
      historySection = nil
      history = nil
    }

    let detailsSection: MenuSectionHeaderView?
    let detailsList: InlineMetricsView?
    if kind != .storage {
      let section = MenuSectionHeaderView(title: "\(kind.title) Details")
      let maximumDetailCount =
        switch kind {
        case .cpu: 4
        case .memory: 6
        case .network: 9
        case .battery: 6
        default: 3
        }
      let list = InlineMetricsView(
        maximumItemCount: maximumDetailCount,
        columnCount: kind == .network ? 1 : 2
      )
      menu.addItem(viewItem(section))
      menu.addItem(viewItem(list))
      detailsSection = section
      detailsList = list
    } else {
      detailsSection = nil
      detailsList = nil
    }

    let storageCapacity: StorageCapacityView?
    if kind == .storage {
      let capacity = StorageCapacityView()
      menu.addItem(viewItem(MenuSectionHeaderView(title: "System Volume")))
      menu.addItem(viewItem(capacity))
      storageCapacity = capacity
    } else {
      storageCapacity = nil
    }

    let section = MenuSectionHeaderView(title: kind.sectionTitle)
    menu.addItem(viewItem(section))

    let list = ResourceListView(
      maximumItemCount: Self.applicationLimit,
      reservesMaximumHeight: false
    )
    menu.addItem(viewItem(ResourceListScrollView(list: list)))
    menu.addItem(.separator())

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(openSettingsAction),
      keyEquivalent: ","
    )
    settingsItem.target = self
    settingsItem.image = NSImage(
      systemSymbolName: "gearshape",
      accessibilityDescription: nil
    )
    menu.addItem(settingsItem)

    return MenuPresentation(
      menu: menu,
      summary: summary,
      historySection: historySection,
      history: history,
      detailsSection: detailsSection,
      detailsList: detailsList,
      section: section,
      list: list,
      storageCapacity: storageCapacity
    )
  }

  private func viewItem(_ view: NSView) -> NSMenuItem {
    let item = NSMenuItem()
    item.view = view
    return item
  }

  private func graphPeriodDidChange() {
    for (kind, presentation) in presentations {
      guard presentation.history != nil else { continue }
      presentation.historySection?.update(
        title: preferences.graphPeriod.historyTitle
      )
      updateHistoryView(for: kind)
    }
  }

  @objc
  private func openSettingsAction() {
    showSettings()
  }

  private func updateSummary(for kind: WidgetKind) {
    guard let presentation = presentations[kind] else { return }
    guard let snapshot = latestSnapshot else {
      presentation.summary.update(
        primary: "–",
        secondary: kind == .network || kind == .storage ? "–" : ""
      )
      return
    }

    switch kind {
    case .cpu:
      presentation.summary.update(
        primary: StatsFormatter.percentage(snapshot.cpuPercent),
        secondary: "",
        primaryMetric: snapshot.cpuPercent
      )
    case .memory:
      presentation.summary.update(
        primary: "\(StatsFormatter.gigabytes(snapshot.memoryUsed)) GB",
        secondary: "",
        primaryMetric: Double(snapshot.memoryUsed)
      )
    case .network:
      presentation.summary.update(
        primary: StatsFormatter.rate(snapshot.downloadBytesPerSecond),
        secondary: StatsFormatter.rate(snapshot.uploadBytesPerSecond),
        primaryMetric: snapshot.downloadBytesPerSecond,
        secondaryMetric: snapshot.uploadBytesPerSecond
      )
    case .storage:
      presentation.summary.update(
        primary: snapshot.storageActivity.map {
          StatsFormatter.rate($0.readBytesPerSecond)
        } ?? "–",
        secondary: snapshot.storageActivity.map {
          StatsFormatter.rate($0.writeBytesPerSecond)
        } ?? "–",
        primaryMetric: snapshot.storageActivity?.readBytesPerSecond,
        secondaryMetric: snapshot.storageActivity?.writeBytesPerSecond
      )
    case .battery:
      presentation.summary.update(
        primary: snapshot.battery.map {
          StatsFormatter.percentage($0.chargePercent)
        } ?? "–",
        secondary: "",
        primaryMetric: snapshot.battery.map(\.chargePercent)
      )
    }
  }

  private func showLoading(for kind: WidgetKind) {
    guard let presentation = presentations[kind] else { return }
    presentation.section.update(title: kind.sectionTitle)
    presentation.list.update(
      [
        ResourceListItem(
          identifier: "state:loading",
          name: kind.loadingTitle,
          value: "",
          image: NSImage(
            systemSymbolName: "hourglass",
            accessibilityDescription: nil
          ),
          accessibilityLabel: kind.loadingTitle
        )
      ],
      animated: false
    )
  }

  private func loadApplicationDetails(for kind: WidgetKind) {
    detailTasks.removeValue(forKey: kind)?.cancel()
    detailGenerations[kind, default: 0] &+= 1
    let generation = detailGenerations[kind]

    detailTasks[kind] = Task { [weak self] in
      guard let self else { return }

      while !Task.isCancelled,
        openMenus.contains(kind),
        detailGenerations[kind] == generation
      {
        switch kind {
        case .cpu:
          async let hardwareSample = cpuHardwareSampler.sample()
          let usages = await processSampler.topCPUApplications(
            limit: Self.applicationLimit
          )
          let hardwareStats = await hardwareSample
          guard
            !Task.isCancelled,
            openMenus.contains(kind),
            detailGenerations[kind] == generation
          else { break }
          cpuHardwareStats = hardwareStats
          sampleSystemStats(forOpenMenu: kind)
          showCPUApplications(usages)
        case .memory:
          let usages = await processSampler.topMemoryApplications(
            limit: Self.applicationLimit
          )
          guard
            !Task.isCancelled,
            openMenus.contains(kind),
            detailGenerations[kind] == generation
          else { break }
          sampleSystemStats(forOpenMenu: kind)
          showMemoryApplications(usages)
          do {
            try await Task.sleep(for: .seconds(1))
          } catch {
            break
          }
        case .network:
          let usages = await networkProcessSampler.topApplications(
            limit: Self.applicationLimit
          )
          guard
            !Task.isCancelled,
            openMenus.contains(kind),
            detailGenerations[kind] == generation
          else { break }
          sampleSystemStats(forOpenMenu: kind)
          showNetworkApplications(usages)
        case .battery:
          let usages = await processSampler.topEnergyApplications(
            limit: Self.applicationLimit
          )
          guard
            !Task.isCancelled,
            openMenus.contains(kind),
            detailGenerations[kind] == generation
          else { break }
          sampleSystemStats(forOpenMenu: kind)
          showBatteryEnergyApplications(usages)
        case .storage:
          let usages = await processSampler.topStorageApplications(
            limit: Self.applicationLimit
          )
          guard
            !Task.isCancelled,
            openMenus.contains(kind),
            detailGenerations[kind] == generation
          else { break }
          sampleSystemStats(forOpenMenu: kind)
          showStorageApplications(usages)
        }
      }

      if detailGenerations[kind] == generation {
        detailTasks[kind] = nil
      }
    }
  }

  private func showCPUApplications(_ usages: [AppCPUUsage]) {
    guard let presentation = presentations[.cpu] else { return }
    let list = presentation.list
    presentation.section.update(title: "CPU Sources")
    let processorCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    let applicationRows = usages.map { usage in
      let systemWidePercent = usage.percent / processorCount
      return ResourceListItem(
        identifier: applicationIdentifier(
          name: usage.name,
          bundlePath: usage.bundlePath
        ),
        name: usage.name,
        value: String(format: "%.1f%%", systemWidePercent),
        image: icon(for: usage.bundlePath),
        accessibilityLabel: "\(usage.name), system-wide CPU usage"
      )
    }
    var rows: [ResourceListItem] = []
    if let breakdown = latestSnapshot?.cpuBreakdown {
      let listedUserPercent = usages.reduce(0) {
        $0 + $1.percent / processorCount
      }
      if breakdown.systemPercent >= 0.05 {
        rows.append(
          ResourceListItem(
            identifier: "cpu:system",
            name: "System & Kernel",
            value: String(format: "%.1f%%", breakdown.systemPercent),
            image: NSImage(
              systemSymbolName: "gearshape.2",
              accessibilityDescription: nil
            ),
            accessibilityLabel: "System and kernel CPU usage"
          )
        )
      }
      let otherPercent = max(0, breakdown.userPercent - listedUserPercent)
      if otherPercent >= 0.05 {
        rows.append(
          ResourceListItem(
            identifier: "cpu:other",
            name: "Other Processes",
            value: String(format: "%.1f%%", otherPercent),
            image: NSImage(
              systemSymbolName: "ellipsis.circle",
              accessibilityDescription: nil
            ),
            accessibilityLabel: "CPU usage from other processes"
          )
        )
      }
    }
    rows.append(contentsOf: applicationRows)
    guard !rows.isEmpty else {
      showEmptyState("No active CPU sources found", in: list)
      return
    }
    list.update(Array(rows.prefix(Self.applicationLimit)))
  }

  private func showMemoryApplications(_ usages: [AppMemoryUsage]) {
    guard let list = presentations[.memory]?.list else { return }
    guard !usages.isEmpty else {
      showEmptyState("No application memory data available", in: list)
      return
    }

    list.update(
      usages.map { usage in
        ResourceListItem(
          identifier: applicationIdentifier(
            name: usage.name,
            bundlePath: usage.bundlePath
          ),
          name: usage.name,
          value: StatsFormatter.memory(usage.bytes),
          image: icon(for: usage.bundlePath),
          accessibilityLabel: "\(usage.name), memory usage"
        )
      }
    )
  }

  private func showNetworkApplications(_ usages: [AppNetworkUsage]) {
    guard let list = presentations[.network]?.list else { return }
    guard !usages.isEmpty else {
      showEmptyState("No external network activity in this sample", in: list)
      return
    }

    list.update(
      usages.map { usage in
        let value =
          "↓\(StatsFormatter.rate(usage.downloadBytesPerSecond))  "
          + "↑\(StatsFormatter.rate(usage.uploadBytesPerSecond))"
        return ResourceListItem(
          identifier: applicationIdentifier(
            name: usage.name,
            bundlePath: usage.bundlePath
          ),
          name: usage.name,
          value: value,
          image: icon(for: usage.bundlePath),
          accessibilityLabel:
            "\(usage.name), received "
            + "\(StatsFormatter.rate(usage.downloadBytesPerSecond)), sent "
            + StatsFormatter.rate(usage.uploadBytesPerSecond)
        )
      }
    )
  }

  private func showBatteryEnergyApplications(_ usages: [AppEnergyUsage]) {
    guard let list = presentations[.battery]?.list else { return }
    guard !usages.isEmpty else {
      showEmptyState("No measurable application energy use", in: list)
      return
    }

    list.update(
      usages.map { usage in
        ResourceListItem(
          identifier: applicationIdentifier(
            name: usage.name,
            bundlePath: usage.bundlePath
          ),
          name: usage.name,
          value: formattedPower(usage.watts),
          image: icon(for: usage.bundlePath),
          accessibilityLabel:
            "\(usage.name), estimated power \(formattedPower(usage.watts))"
        )
      }
    )
  }

  private func showStorageApplications(_ usages: [AppStorageUsage]) {
    guard let presentation = presentations[.storage] else { return }
    let list = presentation.list
    presentation.section.update(title: "Disk Sources")
    let applicationRows = usages.map { usage in
      let value =
        "↓\(StatsFormatter.rate(usage.readBytesPerSecond))  "
        + "↑\(StatsFormatter.rate(usage.writeBytesPerSecond))"
      return ResourceListItem(
        identifier: applicationIdentifier(
          name: usage.name,
          bundlePath: usage.bundlePath
        ),
        name: usage.name,
        value: value,
        image: icon(for: usage.bundlePath),
        accessibilityLabel:
          "\(usage.name), read "
          + "\(StatsFormatter.rate(usage.readBytesPerSecond)), wrote "
          + StatsFormatter.rate(usage.writeBytesPerSecond)
      )
    }
    var rows: [ResourceListItem] = []
    if let activity = latestSnapshot?.storageActivity {
      let listedRead = usages.reduce(0) { $0 + $1.readBytesPerSecond }
      let listedWrite = usages.reduce(0) { $0 + $1.writeBytesPerSecond }
      let unlistedRead = max(0, activity.readBytesPerSecond - listedRead)
      let unlistedWrite = max(0, activity.writeBytesPerSecond - listedWrite)
      if unlistedRead >= 1_024 || unlistedWrite >= 1_024 {
        let value =
          "↓\(StatsFormatter.rate(unlistedRead))  "
          + "↑\(StatsFormatter.rate(unlistedWrite))"
        rows.append(
          ResourceListItem(
            identifier: "storage:system",
            name: "Other Activity",
            value: value,
            image: NSImage(
              systemSymbolName: "gearshape.2",
              accessibilityDescription: nil
            ),
            accessibilityLabel:
              "System and unattributed disk activity, read "
              + "\(StatsFormatter.rate(unlistedRead)), wrote "
              + StatsFormatter.rate(unlistedWrite)
          )
        )
      }
    }
    rows.append(contentsOf: applicationRows)
    guard !rows.isEmpty else {
      showEmptyState("No measurable disk activity in this sample", in: list)
      return
    }
    list.update(Array(rows.prefix(Self.applicationLimit)))
  }

  private func formattedPower(_ watts: Double) -> String {
    if watts >= 1 {
      return String(format: "%.1f W", watts)
    }
    return String(format: "%.0f mW", watts * 1_000)
  }

  private func showWidgetDetails(
    for kind: WidgetKind,
    snapshot: StatsSnapshot
  ) {
    guard let presentation = presentations[kind] else { return }
    presentation.section.update(title: kind.sectionTitle)

    switch kind {
    case .cpu:
      guard let list = presentation.detailsList else { return }
      var items = [
        detailItem(
          id: "cpu:temperature",
          name: "Temperature",
          value: cpuHardwareStats?.temperatureCelsius.map(
            StatsFormatter.temperature
          ) ?? "–",
          symbol: "thermometer.medium"
        ),
        detailItem(
          id: "cpu:frequency",
          name: "Processor Speed",
          value: cpuHardwareStats?.frequencyMHz.map(
            StatsFormatter.frequency
          ) ?? "–",
          symbol: "speedometer"
        ),
      ]
      if let load = snapshot.loadAverages {
        items.append(
          detailItem(
            id: "cpu:load",
            name: "Load Average",
            value: StatsFormatter.loadAverages(load),
            symbol: "chart.line.uptrend.xyaxis"
          )
        )
      }
      items.append(
        detailItem(
          id: "cpu:uptime",
          name: "Uptime",
          value: StatsFormatter.uptime(ProcessInfo.processInfo.systemUptime),
          symbol: "clock.arrow.circlepath"
        )
      )
      list.update(items, animated: false)
    case .memory:
      guard let list = presentation.detailsList else { return }
      var items: [ResourceListItem] = []
      if let breakdown = snapshot.memoryBreakdown {
        items.append(
          detailItem(
            id: "memory:pressure",
            name: "Memory Pressure",
            value: memoryPressureTitle(breakdown.pressureLevel),
            symbol: "gauge.with.dots.needle.50percent",
            valueColor: memoryPressureColor(breakdown.pressureLevel)
          )
        )
        items.append(
          detailItem(
            id: "memory:app",
            name: "App",
            value: StatsFormatter.memory(breakdown.appBytes),
            symbol: "app"
          )
        )
        items.append(
          detailItem(
            id: "memory:wired",
            name: "Wired",
            value: StatsFormatter.memory(breakdown.wiredBytes),
            symbol: "cable.connector"
          )
        )
        items.append(
          detailItem(
            id: "memory:compressed",
            name: "Compressed",
            value: StatsFormatter.memory(breakdown.compressedBytes),
            symbol: "arrow.down.right.and.arrow.up.left"
          )
        )
      }
      items.append(
        detailItem(
          id: "memory:free",
          name: "Free",
          value: snapshot.memoryBreakdown.map {
            StatsFormatter.memory($0.freeBytes)
          } ?? "Unavailable",
          symbol: "circle.dashed"
        )
      )
      if let swap = snapshot.swap {
        items.append(
          detailItem(
            id: "memory:swap",
            name: "Swap",
            value: StatsFormatter.memory(swap.usedBytes),
            symbol: "arrow.left.arrow.right.circle"
          )
        )
      }
      list.update(items, animated: false)
    case .network:
      guard let list = presentation.detailsList else { return }
      var items: [ResourceListItem] = []
      if let details = snapshot.networkDetails {
        let isConnected = details.localAddress != nil
        let interface = [details.interfaceType, details.interfaceName]
          .compactMap { $0 }
          .joined(separator: " · ")
        items.append(
          detailItem(
            id: "network:connection",
            name: "Connection",
            value: isConnected ? (interface.isEmpty ? "Connected" : interface) : "Offline",
            symbol: isConnected ? "checkmark.circle" : "xmark.circle",
            valueColor: isConnected ? .systemGreen : .systemRed
          )
        )
        items.append(
          detailItem(
            id: "network:name",
            name: "Network",
            value: details.networkName
              ?? (isConnected ? "Unavailable" : "Not connected"),
            symbol: "wifi.router"
          )
        )
        if let signal = validWiFiReading(details.signalDBm) {
          items.append(
            detailItem(
              id: "network:signal",
              name: "Signal",
              value: "\(signalQuality(signal)) · \(signal) dBm",
              symbol: "cellularbars"
            )
          )
        }
        items.append(
          detailItem(
            id: "network:link",
            name: "Link",
            value: formattedNetworkLink(details),
            symbol: "speedometer"
          )
        )
        items.append(
          detailItem(
            id: "network:gateway",
            name: "Gateway",
            value: details.gatewayAddress ?? "Unavailable",
            symbol: "point.3.connected.trianglepath.dotted"
          )
        )
        items.append(
          detailItem(
            id: "network:dns",
            name: "DNS",
            value: formattedDNSServers(details.dnsServers),
            symbol: "server.rack"
          )
        )
        items.append(
          detailItem(
            id: "network:local-ip",
            name: "Local IP",
            value: details.localAddress ?? "Unavailable",
            symbol: "globe"
          )
        )
      }
      if preferences.showPublicIP {
        items.append(
          detailItem(
            id: "network:public-ip",
            name: "Public IP",
            value: publicIPValue,
            symbol: "network"
          )
        )
      }
      if let details = snapshot.networkDetails {
        items.append(
          detailItem(
            id: "network:traffic",
            name: "Traffic Totals",
            value: "↓ \(StatsFormatter.memory(details.totalReceivedBytes))"
              + " · ↑ \(StatsFormatter.memory(details.totalSentBytes))",
            symbol: "arrow.up.arrow.down.circle"
          )
        )
      }
      list.update(items, animated: false)
    case .storage:
      guard let capacity = presentation.storageCapacity else { return }
      guard let storage = snapshot.storage else {
        capacity.showUnavailable()
        return
      }
      capacity.update(
        volumeName: storage.volumeName ?? "System Volume",
        usedText: StatsFormatter.memory(storage.usedBytes),
        freeText: StatsFormatter.memory(storage.freeBytes),
        usedFraction: storage.usedPercent / 100
      )
    case .battery:
      guard let list = presentation.detailsList else { return }
      guard let battery = snapshot.battery else {
        list.update(
          [
            detailItem(
              id: "battery:unavailable",
              name: "Status",
              value: "No internal battery detected",
              symbol: "battery.0percent"
            )
          ],
          animated: false
        )
        return
      }
      var items = [
        detailItem(
          id: "battery:state",
          name: "Status",
          value: batteryStateTitle(battery.state),
          symbol: batteryStatusSymbol(battery.state)
        ),
        detailItem(
          id: "battery:power",
          name: batteryPowerTitle(battery.state),
          value: battery.powerWatts.map(formattedPower) ?? "–",
          symbol: "bolt.circle"
        ),
        detailItem(
          id: "battery:time",
          name: battery.state == .charging ? "Until Full" : "Remaining",
          value: batteryTimeValue(battery),
          symbol: "clock",
          showsLoadingShimmer: battery.minutesRemaining == nil
            && (battery.state == .charging || battery.state == .onBattery)
        ),
        detailItem(
          id: "battery:plugged",
          name: "Plugged In",
          value: battery.isPluggedIn ? "Yes" : "No",
          symbol: "powerplug"
        ),
      ]
      if let capacity = battery.maximumCapacityPercent {
        items.append(
          detailItem(
            id: "battery:health",
            name: "Health",
            value: StatsFormatter.percentage(capacity),
            symbol: "heart"
          )
        )
      }
      if let cycleCount = battery.cycleCount {
        items.append(
          detailItem(
            id: "battery:cycles",
            name: "Cycle Count",
            value: String(cycleCount),
            symbol: "arrow.triangle.2.circlepath"
          )
        )
      }
      list.update(
        items,
        animated: false
      )
    }
  }

  private func detailItem(
    id: String,
    name: String,
    value: String,
    symbol: String,
    valueColor: NSColor? = nil,
    showsLoadingShimmer: Bool = false
  ) -> ResourceListItem {
    return ResourceListItem(
      identifier: id,
      name: name,
      value: value,
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
      accessibilityLabel: "\(name), \(value)",
      showsLoadingShimmer: showsLoadingShimmer,
      valueColor: valueColor
    )
  }

  private func batteryStateTitle(_ state: BatteryState) -> String {
    switch state {
    case .charging: "Charging"
    case .full: "Fully Charged"
    case .pluggedIn: "On Hold"
    case .onBattery: "On Battery"
    }
  }

  private func memoryPressureTitle(_ level: MemoryPressureLevel) -> String {
    switch level {
    case .normal: "Normal"
    case .warning: "Strain"
    case .critical: "Heavy"
    case .unavailable: "Unavailable"
    }
  }

  private func memoryPressureColor(_ level: MemoryPressureLevel) -> NSColor {
    switch level {
    case .normal: .systemGreen
    case .warning: .systemOrange
    case .critical: .systemRed
    case .unavailable: .secondaryLabelColor
    }
  }

  private func validWiFiReading(_ value: Int?) -> Int? {
    guard let value, value < 0 else { return nil }
    return value
  }

  private func signalQuality(_ signal: Int) -> String {
    if signal >= -50 { return "Excellent" }
    if signal >= -60 { return "Good" }
    if signal >= -70 { return "Fair" }
    return "Weak"
  }

  private func formattedLinkRate(_ megabitsPerSecond: Double) -> String {
    if megabitsPerSecond >= 1_000 {
      return String(format: "%.2g Gbps", megabitsPerSecond / 1_000)
    }
    return String(format: "%.0f Mbps", megabitsPerSecond)
  }

  private func formattedNetworkLink(_ details: NetworkDetails) -> String {
    var components: [String] = []
    if let rate = details.transmitRateMbps {
      components.append(formattedLinkRate(rate))
    }
    if let channel = details.channelNumber, channel > 0 {
      components.append("Channel \(channel)")
    }
    return components.isEmpty ? "Unavailable" : components.joined(separator: " · ")
  }

  private func formattedDNSServers(_ servers: [String]) -> String {
    guard let first = servers.first else { return "Unavailable" }
    guard servers.count > 1 else { return first }
    return "\(first) · +\(servers.count - 1)"
  }

  private func batteryPowerTitle(_ state: BatteryState) -> String {
    switch state {
    case .charging: "Charging Power"
    case .onBattery: "Discharging Power"
    case .full, .pluggedIn: "Battery Power"
    }
  }

  private func batteryTimeValue(_ battery: BatteryStats) -> String {
    if battery.isPluggedIn, battery.state != .charging {
      return "∞"
    }
    return battery.minutesRemaining.map(StatsFormatter.duration) ?? "Calculating…"
  }

  private func batteryStatusSymbol(_ state: BatteryState) -> String {
    switch state {
    case .charging: "bolt.circle"
    case .full: "checkmark.circle"
    case .pluggedIn: "pause.circle"
    case .onBattery: "bolt.slash.circle"
    }
  }

  private func showEmptyState(_ message: String, in list: ResourceListView) {
    list.update(
      [
        ResourceListItem(
          identifier: "state:empty",
          name: message,
          value: "",
          image: NSImage(
            systemSymbolName: "minus.circle",
            accessibilityDescription: nil
          ),
          accessibilityLabel: message
        )
      ]
    )
  }

  private func applicationIdentifier(name: String, bundlePath: String?) -> String {
    bundlePath.map { "application:\($0)" } ?? "process:\(name)"
  }

  private func icon(for bundlePath: String?) -> NSImage? {
    guard let bundlePath else { return nil }
    if let cached = iconCache[bundlePath] {
      return cached
    }

    let image = NSWorkspace.shared.icon(forFile: bundlePath)
    iconCache[bundlePath] = image
    return image
  }

  private func sampleSystemStats(
    forOpenMenu kind: WidgetKind,
    preserveLatestNetworkRates: Bool = false
  ) {
    autoreleasepool {
      if preserveLatestNetworkRates,
        kind == .network,
        let snapshot = latestSnapshot
      {
        updateSummary(for: kind)
        showWidgetDetails(for: kind, snapshot: snapshot)
        return
      }

      if kind == .battery {
        sampler.invalidateBatteryCache()
      }
      var options = sampleOptions
      if kind == .cpu {
        options.insert(.load)
      } else if kind == .memory {
        options.insert(.swap)
      }
      let snapshot = sampler.sample(options: options)
      applySystemSnapshot(snapshot)
      updateSummary(for: kind)
      showWidgetDetails(for: kind, snapshot: snapshot)
    }
  }

  private func startPowerSourceMonitoring() {
    guard powerSourceRunLoopSource == nil, SystemCapabilities.hasBattery else {
      return
    }
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard
      let source = IOPSNotificationCreateRunLoopSource(
        { context in
          guard let context else { return }
          let controller = Unmanaged<MenuBarController>
            .fromOpaque(context)
            .takeUnretainedValue()
          Task { @MainActor in
            controller.powerSourceDidChange()
          }
        },
        context
      )?.takeRetainedValue()
    else { return }

    powerSourceRunLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  }

  private func stopPowerSourceMonitoring() {
    guard let source = powerSourceRunLoopSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    CFRunLoopSourceInvalidate(source)
    powerSourceRunLoopSource = nil
  }

  private func startNetworkMonitoring() {
    guard networkPathMonitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.networkPathDidChange()
      }
    }
    networkPathMonitor = monitor
    monitor.start(queue: networkMonitorQueue)
  }

  private func stopNetworkMonitoring() {
    networkPathMonitor?.cancel()
    networkPathMonitor = nil
    receivedInitialNetworkPath = false
  }

  private func networkPathDidChange() {
    guard receivedInitialNetworkPath else {
      receivedInitialNetworkPath = true
      return
    }

    sampler.invalidateNetworkIdentityCache()
    publicIPLookupTask?.cancel()
    publicIPLookupTask = nil
    publicIPAddress = nil
    publicIPValue = "Checking…"

    Task { [weak self] in
      guard let self else { return }
      await publicIPLookup.invalidate()
      guard preferences.isEnabled(.network) else { return }
      refresh()
      if openMenus.contains(.network), preferences.showPublicIP {
        refreshPublicIP()
      }
    }
  }

  private func publicIPPreferenceDidChange(_ isEnabled: Bool) {
    publicIPLookupTask?.cancel()
    publicIPLookupTask = nil
    publicIPAddress = nil
    publicIPValue = "Checking…"

    Task { [weak self] in
      guard let self else { return }
      await publicIPLookup.invalidate()
      guard openMenus.contains(.network), let snapshot = latestSnapshot else {
        return
      }
      showWidgetDetails(for: .network, snapshot: snapshot)
      if isEnabled {
        refreshPublicIP()
      }
    }
  }

  private func powerSourceDidChange() {
    sampler.invalidateBatteryCache()
    if openMenus.contains(.battery) {
      sampleSystemStats(forOpenMenu: .battery)
    } else {
      refresh()
    }
  }

  private func refreshPublicIP() {
    guard preferences.showPublicIP else { return }
    guard publicIPLookupTask == nil else { return }
    if publicIPValue == "Unavailable" {
      publicIPValue = "Checking…"
    }

    publicIPLookupTask = Task { [weak self] in
      guard let self else { return }
      let result = await publicIPLookup.fetch()
      guard !Task.isCancelled else { return }

      if let result {
        publicIPAddress = result.ipAddress
        let flag = StatsFormatter.countryFlag(countryCode: result.countryCode)
        publicIPValue = [flag, result.ipAddress]
          .compactMap { $0 }
          .joined(separator: " ")
      } else {
        publicIPAddress = nil
        publicIPValue = "Unavailable"
      }
      publicIPLookupTask = nil

      if openMenus.contains(.network), let snapshot = latestSnapshot {
        showWidgetDetails(for: .network, snapshot: snapshot)
      }
    }
  }

  private func applySystemSnapshot(_ snapshot: StatsSnapshot) {
    latestSnapshot = snapshot
    recordHistory(from: snapshot)

    if preferences.isEnabled(.cpu) {
      updateCPUHighlight(for: snapshot.cpuPercent)
      setTitle(
        StatsFormatter.percentage(snapshot.cpuPercent),
        for: .cpu,
        color: isCPUHighlighted ? .systemOrange : .controlTextColor
      )
    }
    if preferences.isEnabled(.memory) {
      setTitle(
        StatsFormatter.percentage(snapshot.memoryPercent),
        for: .memory
      )
    }
    if preferences.isEnabled(.network) {
      setNetworkRates(
        received: snapshot.downloadBytesPerSecond,
        sent: snapshot.uploadBytesPerSecond
      )
    }
    if preferences.isEnabled(.storage) {
      setTitle(
        snapshot.storage.map { StatsFormatter.percentage($0.usedPercent) } ?? "–",
        for: .storage
      )
    }
    if preferences.isEnabled(.battery) {
      if let battery = snapshot.battery {
        updateBatteryStatusIcon(for: battery)
      }
      setTitle(
        snapshot.battery.map { StatsFormatter.percentage($0.chargePercent) } ?? "–",
        for: .battery
      )
    }
  }

  private func recordHistory(from snapshot: StatsSnapshot) {
    let now = ContinuousClock.now
    for kind in [WidgetKind.cpu, .memory, .network, .storage]
    where preferences.isEnabled(kind) {
      let values: (primary: Double, secondary: Double?) =
        switch kind {
        case .cpu:
          (snapshot.cpuPercent, nil)
        case .memory:
          (snapshot.memoryPercent, nil)
        case .network:
          (
            snapshot.downloadBytesPerSecond,
            snapshot.uploadBytesPerSecond
          )
        case .storage:
          (
            snapshot.storageActivity?.readBytesPerSecond ?? 0,
            snapshot.storageActivity?.writeBytesPerSecond
          )
        default:
          (0, nil)
        }

      var points = historyPoints[kind, default: []]
      if let last = points.last,
        last.capturedAt.duration(to: now) < Self.minimumHistoryInterval
      {
        continue
      }

      points.append(
        HistoryPoint(
          capturedAt: now,
          primary: max(0, values.primary),
          secondary: values.secondary.map { max(0, $0) }
        )
      )
      points.removeAll {
        $0.capturedAt.duration(to: now) > GraphPeriod.maximumDuration
      }
      historyPoints[kind] = points

      if openMenus.contains(kind) {
        updateHistoryView(for: kind, at: now)
      }
    }
  }

  private func updateHistoryView(
    for kind: WidgetKind,
    at now: ContinuousClock.Instant = .now
  ) {
    guard let view = presentations[kind]?.history else { return }
    let historyDuration = preferences.graphPeriod.duration
    let points = historyPoints[kind, default: []].filter {
      $0.capturedAt.duration(to: now) <= historyDuration
    }
    let historySeconds = Self.seconds(historyDuration)
    let positions = points.map { point in
      let age = Self.seconds(point.capturedAt.duration(to: now))
      return 1 - min(1, max(0, age / historySeconds))
    }
    view.update(
      positions: positions,
      primaryValues: points.map(\.primary),
      secondaryValues: points.compactMap(\.secondary),
      historyInterval: preferences.graphPeriod.interval,
      accessibilityLabel: preferences.graphPeriod.historyTitle
    )
  }

  private static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }

  private func setTitle(
    _ title: String,
    for kind: WidgetKind,
    color: NSColor = .controlTextColor
  ) {
    guard let button = statusItems[kind]?.button else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: color,
    ]
    if button.attributedTitle.string != title
      || button.attributedTitle.attribute(
        .foregroundColor,
        at: 0,
        effectiveRange: nil
      ) as? NSColor != color
    {
      button.attributedTitle = NSAttributedString(
        string: title,
        attributes: attributes
      )
    }
    button.setAccessibilityValue(title)
  }

  private func updateCPUHighlight(for percentage: Double) {
    if percentage >= 85 {
      consecutiveHighCPUSamples += 1
      if consecutiveHighCPUSamples >= 3 {
        isCPUHighlighted = true
      }
    } else {
      consecutiveHighCPUSamples = 0
      isCPUHighlighted = false
    }
  }

  private func setNetworkRates(received: Double, sent: Double) {
    networkStatusView?.update(
      received: StatsFormatter.rate(received),
      sent: StatsFormatter.rate(sent)
    )
    statusItems[.network]?.button?.setAccessibilityValue(
      "Received \(StatsFormatter.rate(received)), sent \(StatsFormatter.rate(sent))"
    )
  }

  private func updateBatteryStatusIcon(for battery: BatteryStats) {
    let symbolName: String
    if battery.isPluggedIn {
      symbolName = "battery.100percent.bolt"
    } else {
      symbolName =
        switch battery.chargePercent {
        case ..<12.5: "battery.0percent"
        case ..<37.5: "battery.25percent"
        case ..<62.5: "battery.50percent"
        case ..<87.5: "battery.75percent"
        default: "battery.100percent"
        }
    }

    guard symbolName != batteryStatusSymbolName else { return }
    batteryStatusSymbolName = symbolName

    let image = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: battery.isPluggedIn
        ? "Battery charging"
        : "Battery charge"
    )
    image?.isTemplate = true
    statusItems[.battery]?.button?.image = image
    presentations[.battery]?.summary.updateSymbol(symbolName)
  }
}

private actor PublicIPLookup {
  struct Result: Sendable {
    let ipAddress: String
    let countryCode: String
  }

  private struct LocationResponse: Decodable {
    let ip: String
    let countryCode: String
    let success: Bool

    enum CodingKeys: String, CodingKey {
      case ip
      case countryCode = "country_code"
      case success
    }
  }

  private struct CountryResponse: Decodable {
    let ip: String
    let country: String
  }

  private struct IPResponse: Decodable {
    let ip: String
  }

  private let session: URLSession
  private var cachedResult: (value: Result, expiresAt: Date)?

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    session = URLSession(configuration: configuration)
  }

  func fetch() async -> Result? {
    if let cachedResult, cachedResult.expiresAt > Date() {
      return cachedResult.value
    }

    let result: Result?
    if let response: LocationResponse = await response(
      from: "https://ipwho.is/"
    ), response.success {
      result = Result(
        ipAddress: response.ip,
        countryCode: response.countryCode
      )
    } else if let response: CountryResponse = await response(
      from: "https://api.country.is/"
    ) {
      result = Result(ipAddress: response.ip, countryCode: response.country)
    } else if let response: IPResponse = await response(
      from: "https://api.ipify.org?format=json"
    ) {
      result = Result(ipAddress: response.ip, countryCode: "")
    } else {
      result = nil
    }

    if let result {
      cachedResult = (result, Date().addingTimeInterval(30 * 60))
    }
    return result
  }

  func invalidate() {
    cachedResult = nil
  }

  private func response<Value: Decodable>(
    from urlString: String
  ) async -> Value? {
    guard let url = URL(string: urlString) else { return nil }
    do {
      let (data, response) = try await session.data(from: url)
      guard
        let httpResponse = response as? HTTPURLResponse,
        httpResponse.statusCode == 200
      else { return nil }
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      return nil
    }
  }
}
