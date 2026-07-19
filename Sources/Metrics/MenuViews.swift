import AppKit
import MetricsCore
import QuartzCore
import SwiftUI

private enum MenuViewLayout {
  static let width: CGFloat = 320
  static let horizontalPadding: CGFloat = 14
  static let iconSize: CGFloat = 18
  static let textGap: CGFloat = 10
}

enum ResourceHistoryValueStyle {
  case percentage
  case rate(primaryLabel: String, secondaryLabel: String)

  func text(primary: Double, secondary: Double?) -> String {
    switch self {
    case .percentage:
      return StatsFormatter.percentage(primary)
    case .rate(let primaryLabel, let secondaryLabel):
      let primaryText = "\(primaryLabel) \(StatsFormatter.rate(primary))"
      guard let secondary else { return primaryText }
      return "\(primaryText)   \(secondaryLabel) \(StatsFormatter.rate(secondary))"
    }
  }
}

@MainActor
private final class ResourceHistoryModel: ObservableObject {
  @Published private(set) var revision = 0
  @Published var isAnimationActive = false
  private(set) var historyInterval: TimeInterval
  private(set) var positions: [Double] = []
  private(set) var primaryValues: [Double] = []
  private(set) var secondaryValues: [Double] = []
  private(set) var referenceDate = Date()

  init(historyInterval: TimeInterval) {
    self.historyInterval = max(1, historyInterval)
  }

  func update(
    positions: [Double],
    primaryValues: [Double],
    secondaryValues: [Double],
    historyInterval: TimeInterval
  ) {
    self.positions = positions
    self.primaryValues = primaryValues
    self.secondaryValues = secondaryValues
    self.historyInterval = max(1, historyInterval)
    referenceDate = Date()
    revision &+= 1
  }
}

@MainActor
private struct ResourceHistoryContent: View {
  @ObservedObject var model: ResourceHistoryModel
  let primaryColor: Color
  let secondaryColor: Color?
  let fixedMaximum: Double?
  let valueStyle: ResourceHistoryValueStyle

  @State private var hoverLocation: CGPoint?
  @State private var pendingHoverLocation: CGPoint?

  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 1.0 / 30.0,
        paused: !model.isAnimationActive
      )
    ) { timeline in
      Canvas { context, size in
        drawGrid(in: &context, size: size)

        let elapsed = max(
          0,
          timeline.date.timeIntervalSince(model.referenceDate)
        )
        let positionOffset = elapsed / model.historyInterval
        let positions = model.positions.map { $0 - positionOffset }

        let observedMaximum = max(
          model.primaryValues.max() ?? 0,
          model.secondaryValues.max() ?? 0
        )
        let maximum = max(1, fixedMaximum ?? observedMaximum * 1.12)

        drawSeries(
          model.primaryValues,
          positions: positions,
          color: primaryColor,
          fillsArea: secondaryColor == nil,
          maximum: maximum,
          in: &context,
          size: size
        )
        if let secondaryColor {
          drawSeries(
            model.secondaryValues,
            positions: positions,
            color: secondaryColor,
            fillsArea: false,
            maximum: maximum,
            in: &context,
            size: size
          )
        }
        if let hoverLocation {
          drawInspection(
            at: hoverLocation,
            positions: positions,
            maximum: maximum,
            in: &context,
            size: size
          )
        }
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.035))
    )
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let location):
        if hoverLocation != nil {
          hoverLocation = location
        } else if let pendingHoverLocation,
          hypot(
            location.x - pendingHoverLocation.x,
            location.y - pendingHoverLocation.y
          ) >= 0.5
        {
          hoverLocation = location
        } else if pendingHoverLocation == nil {
          pendingHoverLocation = location
        }
      case .ended:
        hoverLocation = nil
        pendingHoverLocation = nil
      }
    }
    .onReceive(model.$isAnimationActive) { isActive in
      guard !isActive else { return }
      hoverLocation = nil
      pendingHoverLocation = nil
    }
    .padding(.horizontal, MenuViewLayout.horizontalPadding)
    .accessibilityHidden(true)
  }

  private func drawGrid(
    in context: inout GraphicsContext,
    size: CGSize
  ) {
    for fraction in [0.25, 0.5, 0.75] {
      var path = Path()
      let y = size.height * fraction
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
      context.stroke(
        path,
        with: .color(.secondary.opacity(0.10)),
        lineWidth: 0.5
      )
    }
  }

  private func drawSeries(
    _ values: [Double],
    positions: [Double],
    color: Color,
    fillsArea: Bool,
    maximum: Double,
    in context: inout GraphicsContext,
    size: CGSize
  ) {
    guard !values.isEmpty else { return }

    let visiblePositions = positions.suffix(values.count)
    let points = zip(visiblePositions, values).map { position, value in
      CGPoint(
        x: size.width * min(1, max(0, position)),
        y: size.height * (1 - min(1, max(0, value) / maximum))
      )
    }

    var line = Path()
    line.move(to: CGPoint(x: 0, y: points[0].y))
    line.addLine(to: points[0])
    for point in points.dropFirst() {
      line.addLine(to: point)
    }
    line.addLine(to: CGPoint(x: size.width, y: points.last?.y ?? 0))

    if fillsArea {
      var area = line
      area.addLine(to: CGPoint(x: size.width, y: size.height))
      area.addLine(to: CGPoint(x: 0, y: size.height))
      area.closeSubpath()
      context.fill(area, with: .color(color.opacity(0.10)))
    }

    context.stroke(
      line,
      with: .color(color),
      style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
    )
  }

  private func drawInspection(
    at location: CGPoint,
    positions: [Double],
    maximum: Double,
    in context: inout GraphicsContext,
    size: CGSize
  ) {
    guard !positions.isEmpty, !model.primaryValues.isEmpty, size.width > 0 else {
      return
    }

    let targetPosition = min(1, max(0, location.x / size.width))
    let visibleIndices = positions.indices.filter {
      positions[$0] >= 0 && positions[$0] <= 1
    }
    guard
      let index = visibleIndices.min(by: {
        abs(positions[$0] - targetPosition)
          < abs(positions[$1] - targetPosition)
      }),
      index < model.primaryValues.count
    else { return }

    let position = positions[index]
    let x = size.width * position
    let primary = model.primaryValues[index]
    let primaryY = yPosition(for: primary, maximum: maximum, height: size.height)
    let secondary = secondaryValue(atPositionIndex: index, positionCount: positions.count)

    var guide = Path()
    guide.move(to: CGPoint(x: x, y: 0))
    guide.addLine(to: CGPoint(x: x, y: size.height))
    context.stroke(
      guide,
      with: .color(.secondary.opacity(0.34)),
      lineWidth: 0.5
    )
    drawInspectionPoint(
      at: CGPoint(x: x, y: primaryY),
      color: primaryColor,
      in: &context
    )
    if let secondary, let secondaryColor {
      drawInspectionPoint(
        at: CGPoint(
          x: x,
          y: yPosition(
            for: secondary,
            maximum: maximum,
            height: size.height
          )
        ),
        color: secondaryColor,
        in: &context
      )
    }

    let age = max(0, (1 - position) * model.historyInterval)
    let label = "\(ageText(age))  ·  \(valueStyle.text(primary: primary, secondary: secondary))"
    let text = context.resolve(
      Text(label)
        .font(.system(size: 9.5, weight: .medium))
        .foregroundColor(.secondary)
    )
    let textSize = text.measure(
      in: CGSize(width: max(0, size.width - 20), height: 18)
    )
    let preferredX = x + 6
    let textX =
      preferredX + textSize.width <= size.width - 5
      ? preferredX
      : max(5, x - 6 - textSize.width)
    context.draw(
      text,
      at: CGPoint(x: textX, y: 5),
      anchor: .topLeading
    )
  }

  private func secondaryValue(
    atPositionIndex index: Int,
    positionCount: Int
  ) -> Double? {
    let startIndex = positionCount - model.secondaryValues.count
    let secondaryIndex = index - startIndex
    guard model.secondaryValues.indices.contains(secondaryIndex) else { return nil }
    return model.secondaryValues[secondaryIndex]
  }

  private func yPosition(
    for value: Double,
    maximum: Double,
    height: CGFloat
  ) -> CGFloat {
    height * (1 - min(1, max(0, value) / maximum))
  }

  private func drawInspectionPoint(
    at point: CGPoint,
    color: Color,
    in context: inout GraphicsContext
  ) {
    let rect = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
    context.fill(Path(ellipseIn: rect), with: .color(color))
    context.stroke(
      Path(ellipseIn: rect),
      with: .color(Color(nsColor: .windowBackgroundColor)),
      lineWidth: 1
    )
  }

  private func ageText(_ age: TimeInterval) -> String {
    let seconds = Int(age.rounded())
    if seconds <= 1 { return "Now" }
    if seconds < 60 { return "\(seconds)s ago" }
    return "\(seconds / 60)m \(seconds % 60)s ago"
  }
}

@MainActor
final class ResourceHistoryView: NSView {
  private static let height: CGFloat = 74

  private let model: ResourceHistoryModel

  override var isFlipped: Bool { true }

  init(
    primaryColor: NSColor,
    secondaryColor: NSColor? = nil,
    fixedMaximum: Double? = nil,
    valueStyle: ResourceHistoryValueStyle,
    historyInterval: TimeInterval,
    accessibilityLabel: String
  ) {
    model = ResourceHistoryModel(historyInterval: historyInterval)
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: Self.height
      )
    )

    let content = ResourceHistoryContent(
      model: model,
      primaryColor: Color(nsColor: primaryColor),
      secondaryColor: secondaryColor.map(Color.init(nsColor:)),
      fixedMaximum: fixedMaximum,
      valueStyle: valueStyle
    )
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = bounds
    hostingView.autoresizingMask = [.width, .height]
    hostingView.setAccessibilityElement(false)
    addSubview(hostingView)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(accessibilityLabel)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: Self.height)
  }

  func update(
    positions: [Double],
    primaryValues: [Double],
    secondaryValues: [Double],
    historyInterval: TimeInterval,
    accessibilityLabel: String
  ) {
    model.update(
      positions: positions,
      primaryValues: primaryValues,
      secondaryValues: secondaryValues,
      historyInterval: historyInterval
    )
    setAccessibilityLabel(accessibilityLabel)
  }

  func setAnimationActive(_ isActive: Bool) {
    model.isAnimationActive = isActive
  }
}

@MainActor
private final class StorageCapacityModel: ObservableObject {
  @Published var volumeName = "Storage"
  @Published var usedText = "—"
  @Published var freeText = "—"
  @Published var usedFraction = 0.0
  @Published var isAvailable = false
}

@MainActor
private struct StorageCapacityContent: View {
  @ObservedObject var model: StorageCapacityModel

  var body: some View {
    VStack(spacing: 9) {
      HStack(alignment: .top, spacing: 12) {
        metric(
          label: "Volume",
          value: model.volumeName,
          alignment: .leading
        )
        Spacer(minLength: 8)
        metric(
          label: "Used",
          value: model.isAvailable
            ? "\(Int((model.usedFraction * 100).rounded()))%"
            : "Unavailable",
          alignment: .trailing
        )
      }

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.secondary.opacity(0.18))
          Capsule()
            .fill(Color.accentColor)
            .frame(
              width: geometry.size.width * min(1, max(0, model.usedFraction))
            )
        }
      }
      .frame(height: 8)

      HStack {
        Text("Used  \(model.usedText)")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text("Free  \(model.freeText)")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .monospacedDigit()
    }
    .padding(.horizontal, MenuViewLayout.horizontalPadding)
    .padding(.vertical, 4)
  }

  private func metric(
    label: String,
    value: String,
    alignment: HorizontalAlignment
  ) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      Text(label.uppercased())
        .font(.system(size: 9, weight: .medium))
        .tracking(0.45)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(value)
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

@MainActor
final class StorageCapacityView: NSView {
  private static let height: CGFloat = 78
  private let model = StorageCapacityModel()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: Self.height
      )
    )

    let hostingView = NSHostingView(
      rootView: StorageCapacityContent(model: model)
    )
    hostingView.frame = bounds
    hostingView.autoresizingMask = [.width, .height]
    hostingView.setAccessibilityElement(false)
    addSubview(hostingView)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Storage capacity")
  }

  convenience init() {
    self.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: Self.height)
  }

  func update(
    volumeName: String,
    usedText: String,
    freeText: String,
    usedFraction: Double
  ) {
    model.volumeName = volumeName
    model.usedText = usedText
    model.freeText = freeText
    model.usedFraction = min(1, max(0, usedFraction))
    model.isAvailable = true
    setAccessibilityValue(
      "\(usedText) used, \(freeText) free"
    )
  }

  func showUnavailable() {
    model.volumeName = "Storage"
    model.usedText = "—"
    model.freeText = "—"
    model.usedFraction = 0
    model.isAvailable = false
    setAccessibilityValue("Unavailable")
  }
}

@MainActor
final class NetworkStatusView: NSView {
  static let preferredWidth: CGFloat = 72

  private static let font = NSFont.monospacedDigitSystemFont(
    ofSize: 10,
    weight: .regular
  )
  private static let arrowFont = NSFont.systemFont(
    ofSize: 10,
    weight: .semibold
  )
  private static let lineHeight: CGFloat = 10.5

  private var received = "—"
  private var sent = "—"

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let contentHeight = Self.lineHeight * 2
    let originY = floor((bounds.height - contentHeight) / 2)
    let contentWidth: CGFloat = 64
    let originX = floor((bounds.width - contentWidth) / 2)

    drawLine(
      arrow: "↑",
      arrowColor: .systemOrange,
      value: sent,
      origin: NSPoint(x: originX, y: originY),
      width: contentWidth
    )
    drawLine(
      arrow: "↓",
      arrowColor: .systemBlue,
      value: received,
      origin: NSPoint(x: originX, y: originY + Self.lineHeight),
      width: contentWidth
    )
  }

  func update(received: String, sent: String) {
    guard self.received != received || self.sent != sent else { return }
    self.received = received
    self.sent = sent
    needsDisplay = true
  }

  private func drawLine(
    arrow: String,
    arrowColor: NSColor,
    value: String,
    origin: NSPoint,
    width: CGFloat
  ) {
    let arrowWidth: CGFloat = 8
    let gap: CGFloat = 4
    draw(
      arrow,
      in: NSRect(
        x: origin.x,
        y: origin.y,
        width: arrowWidth,
        height: Self.lineHeight
      ),
      alignment: .center,
      color: arrowColor,
      font: Self.arrowFont
    )
    draw(
      value,
      in: NSRect(
        x: origin.x + arrowWidth + gap,
        y: origin.y,
        width: width - arrowWidth - gap,
        height: Self.lineHeight
      ),
      alignment: .left,
      color: .controlTextColor,
      font: Self.font
    )
  }

  private func draw(
    _ text: String,
    in rect: NSRect,
    alignment: NSTextAlignment,
    color: NSColor,
    font: NSFont
  ) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = alignment
    paragraphStyle.lineBreakMode = .byClipping
    NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle,
      ]
    ).draw(
      with: rect,
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
    )
  }

}

private enum NumericTextStyle: Equatable {
  case primary
  case balanced
}

@MainActor
private final class NumericTextModel: ObservableObject {
  @Published var text = ""
  @Published var metric = 0.0
}

@MainActor
private struct NumericTextContent: View {
  @ObservedObject var model: NumericTextModel
  let style: NumericTextStyle
  let prefix: String?
  let accentColor: NSColor?

  var body: some View {
    HStack(spacing: 4) {
      if let prefix, let accentColor {
        Text(prefix)
          .font(font)
          .foregroundColor(Color(nsColor: accentColor))
      }

      transitioningText
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: .infinity,
      alignment: alignment
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var transitioningText: some View {
    if #available(macOS 14.0, *) {
      text.contentTransition(.numericText(value: model.metric))
    } else {
      text
    }
  }

  private var text: some View {
    Text(model.text)
      .font(font)
      .monospacedDigit()
      .foregroundColor(.primary)
      .lineLimit(1)
      .truncationMode(style == .primary ? .head : .tail)
  }

  private var font: Font {
    switch style {
    case .primary:
      .system(size: 15, weight: .semibold)
    case .balanced:
      .system(size: 14, weight: .semibold)
    }
  }

  private var alignment: Alignment {
    switch style {
    case .primary: .trailing
    case .balanced: .center
    }
  }
}

@MainActor
private final class NumericTextView: NSView {
  private static let opticalVerticalOffset: CGFloat = -1

  private let style: NumericTextStyle
  private let prefix: String?
  private let accentColor: NSColor?
  private let model = NumericTextModel()
  private let fallbackField = NSTextField(labelWithString: "")
  private var hostingView: NSHostingView<NumericTextContent>?
  private var animationsActive = false

  override var isFlipped: Bool { true }

  init(
    style: NumericTextStyle,
    prefix: String? = nil,
    accentColor: NSColor? = nil
  ) {
    self.style = style
    self.prefix = prefix
    self.accentColor = accentColor
    super.init(frame: .zero)

    switch style {
    case .primary:
      fallbackField.font = .monospacedDigitSystemFont(
        ofSize: 15,
        weight: .semibold
      )
      fallbackField.textColor = .labelColor
      fallbackField.alignment = .right
      fallbackField.lineBreakMode = .byTruncatingHead
    case .balanced:
      fallbackField.font = .monospacedDigitSystemFont(
        ofSize: 14,
        weight: .semibold
      )
      fallbackField.textColor = .labelColor
      fallbackField.alignment = .center
      fallbackField.lineBreakMode = .byTruncatingTail
    }
    fallbackField.setAccessibilityElement(false)
    addSubview(fallbackField)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    let contentBounds = bounds.offsetBy(
      dx: 0,
      dy: Self.opticalVerticalOffset
    )
    fallbackField.frame = contentBounds
    hostingView?.frame = contentBounds
  }

  func update(_ text: String, metric: Double?, animated: Bool) {
    if hostingView == nil {
      updateFallback(text)
    }

    let shouldAnimate =
      animated
      && animationsActive
      && metric != nil
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if shouldAnimate {
      withAnimation(.easeOut(duration: 0.22)) {
        model.text = text
        if let metric {
          model.metric = metric
        }
      }
    } else {
      model.text = text
      if let metric {
        model.metric = metric
      }
    }
  }

  func setAnimationsActive(_ active: Bool) {
    animationsActive = active
    guard active, #available(macOS 14.0, *) else { return }
    ensureHostingView()
  }

  private func ensureHostingView() {
    guard hostingView == nil else { return }
    let hostingView = NSHostingView(
      rootView: NumericTextContent(
        model: model,
        style: style,
        prefix: prefix,
        accentColor: accentColor
      )
    )
    hostingView.frame = bounds
    hostingView.setAccessibilityElement(false)
    addSubview(hostingView)
    fallbackField.isHidden = true
    self.hostingView = hostingView
  }

  private func updateFallback(_ text: String) {
    guard let prefix, let accentColor else {
      fallbackField.stringValue = text
      return
    }

    let value = NSMutableAttributedString(
      string: "\(prefix) ",
      attributes: [
        .font: fallbackField.font ?? NSFont.systemFont(ofSize: 14),
        .foregroundColor: accentColor,
      ]
    )
    value.append(
      NSAttributedString(
        string: text,
        attributes: [
          .font: fallbackField.font ?? NSFont.systemFont(ofSize: 14),
          .foregroundColor: NSColor.labelColor,
        ]
      )
    )
    fallbackField.attributedStringValue = value
  }
}

@MainActor
final class ResourceSummaryView: NSView {
  private static let height: CGFloat = 50
  private static let iconSize: CGFloat = 22
  private static let iconConfiguration = NSImage.SymbolConfiguration(
    pointSize: 20,
    weight: .regular
  )

  private let symbolView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let primaryField: NumericTextView
  private let secondaryField: NumericTextView?
  private let valueLabels: (primary: String, secondary: String)?
  private let symbolHorizontalOffset: CGFloat
  private var primaryMetric: Double?
  private var secondaryMetric: Double?
  private var dragStartMouseLocation: NSPoint?
  private var dragStartWindowOrigin: NSPoint?

  override var isFlipped: Bool { true }

  init(
    symbolName: String,
    title: String,
    primary: String,
    secondary: String,
    valueLabels: (primary: String, secondary: String)? = nil
  ) {
    let balanced = valueLabels != nil
    self.valueLabels = valueLabels
    self.symbolHorizontalOffset = symbolName.hasPrefix("battery") ? 1 : 0
    self.primaryField = NumericTextView(
      style: balanced ? .balanced : .primary,
      prefix: balanced ? "↓" : nil,
      accentColor: balanced ? .systemBlue : nil
    )
    self.secondaryField =
      balanced
      ? NumericTextView(
        style: .balanced,
        prefix: "↑",
        accentColor: .systemOrange
      )
      : nil
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: Self.height
      )
    )

    let symbol = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(Self.iconConfiguration)
    symbol?.isTemplate = true
    symbolView.image = symbol
    symbolView.imageScaling = .scaleProportionallyDown
    symbolView.contentTintColor = .secondaryLabelColor
    symbolView.setAccessibilityElement(false)

    titleField.font = .systemFont(ofSize: 15, weight: .semibold)
    titleField.textColor = .labelColor
    titleField.lineBreakMode = .byTruncatingTail
    titleField.setAccessibilityElement(false)

    addSubview(symbolView)
    addSubview(titleField)
    addSubview(primaryField)
    if let secondaryField {
      addSubview(secondaryField)
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(title)

    titleField.stringValue = title
    update(primary: primary, secondary: secondary, animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: Self.height)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    dragStartMouseLocation = NSEvent.mouseLocation
    dragStartWindowOrigin = window?.frame.origin
  }

  override func mouseDragged(with event: NSEvent) {
    guard
      let window,
      let dragStartMouseLocation,
      let dragStartWindowOrigin
    else { return }
    let location = NSEvent.mouseLocation
    window.setFrameOrigin(
      NSPoint(
        x: dragStartWindowOrigin.x + location.x - dragStartMouseLocation.x,
        y: dragStartWindowOrigin.y + location.y - dragStartMouseLocation.y
      )
    )
  }

  override func mouseUp(with event: NSEvent) {
    dragStartMouseLocation = nil
    dragStartWindowOrigin = nil
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .openHand)
  }

  func updateSymbol(_ symbolName: String) {
    let symbol = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(Self.iconConfiguration)
    symbol?.isTemplate = true
    symbolView.image = symbol
  }

  override func layout() {
    super.layout()

    let padding = MenuViewLayout.horizontalPadding
    let rowCenterY = bounds.midY
    let textLeading = padding + Self.iconSize + MenuViewLayout.textGap

    symbolView.frame = NSRect(
      x: padding + symbolHorizontalOffset,
      y: rowCenterY - Self.iconSize / 2 - 1,
      width: Self.iconSize,
      height: Self.iconSize
    )

    if valueLabels != nil {
      let valuesLeading = max(textLeading + 68, bounds.width * 0.39)
      let columnGap: CGFloat = 6
      let columnWidth = max(
        0,
        (bounds.width - padding - valuesLeading - columnGap) / 2
      )

      titleField.frame = NSRect(
        x: textLeading,
        y: rowCenterY - 11,
        width: max(0, valuesLeading - textLeading - 8),
        height: 22
      )
      primaryField.frame = NSRect(
        x: valuesLeading,
        y: rowCenterY - 11,
        width: columnWidth,
        height: 22
      )
      secondaryField?.frame = NSRect(
        x: valuesLeading + columnWidth + columnGap,
        y: rowCenterY - 11,
        width: columnWidth,
        height: 22
      )
      return
    }

    let primaryWidth = min(160, max(100, bounds.width * 0.5))
    let primaryLeading = bounds.width - padding - primaryWidth

    titleField.frame = NSRect(
      x: textLeading,
      y: rowCenterY - 11,
      width: max(0, primaryLeading - textLeading - 8),
      height: 22
    )
    primaryField.frame = NSRect(
      x: primaryLeading,
      y: rowCenterY - 11,
      width: primaryWidth,
      height: 22
    )
  }

  func update(
    primary: String,
    secondary: String,
    primaryMetric: Double? = nil,
    secondaryMetric: Double? = nil,
    animated: Bool = true
  ) {
    primaryField.update(
      primary,
      metric: primaryMetric,
      animated: animated && self.primaryMetric != nil && primaryMetric != nil
    )
    secondaryField?.update(
      secondary,
      metric: secondaryMetric,
      animated: animated && self.secondaryMetric != nil && secondaryMetric != nil
    )
    self.primaryMetric = primaryMetric
    self.secondaryMetric = secondaryMetric

    let value: String
    if let valueLabels {
      value = "\(valueLabels.primary) \(primary), \(valueLabels.secondary) \(secondary)"
    } else {
      value = secondary.isEmpty ? primary : "\(primary), \(secondary)"
    }
    setAccessibilityValue(value)
  }

  func setAnimationsActive(_ active: Bool) {
    primaryField.setAnimationsActive(active)
    secondaryField?.setAnimationsActive(active)
    if !active {
      primaryMetric = nil
      secondaryMetric = nil
    }
  }
}

@MainActor
final class MenuSectionHeaderView: NSView {
  static let height: CGFloat = 30

  private let titleField = NSTextField(labelWithString: "")

  override var isFlipped: Bool { true }

  init(title: String) {
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: Self.height
      )
    )

    titleField.font = .systemFont(ofSize: 10, weight: .semibold)
    titleField.textColor = .secondaryLabelColor
    titleField.alignment = .center
    titleField.lineBreakMode = .byTruncatingTail
    titleField.setAccessibilityElement(false)
    addSubview(titleField)

    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    update(title: title)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: Self.height)
  }

  override func layout() {
    super.layout()
    let maximumWidth = max(0, bounds.width - MenuViewLayout.horizontalPadding * 2 - 52)
    let titleWidth = min(maximumWidth, titleField.intrinsicContentSize.width + 4)
    let titleHeight: CGFloat = 14
    titleField.frame = NSRect(
      x: (bounds.width - titleWidth) / 2,
      y: (bounds.height - titleHeight) / 2,
      width: titleWidth,
      height: titleHeight
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let gap: CGFloat = 10
    let lineThickness = 1 / max(window?.backingScaleFactor ?? 2, 1)
    let lineY = titleField.frame.midY - lineThickness / 2
    let color = NSColor.separatorColor.withAlphaComponent(0.36)
    color.setFill()

    NSRect(
      x: MenuViewLayout.horizontalPadding,
      y: lineY,
      width: max(
        0,
        titleField.frame.minX - gap - MenuViewLayout.horizontalPadding
      ),
      height: lineThickness
    ).fill()
    let rightLeading = titleField.frame.maxX + gap
    NSRect(
      x: rightLeading,
      y: lineY,
      width: max(
        0,
        bounds.width - MenuViewLayout.horizontalPadding - rightLeading
      ),
      height: lineThickness
    ).fill()
  }

  func update(title: String) {
    let displayTitle = title.uppercased()
    if titleField.stringValue != displayTitle {
      titleField.attributedStringValue = NSAttributedString(
        string: displayTitle,
        attributes: [
          .font: titleField.font as Any,
          .foregroundColor: NSColor.secondaryLabelColor,
          .kern: 1.1,
        ]
      )
      needsLayout = true
      needsDisplay = true
    }
    setAccessibilityLabel(title)
  }
}

private struct InlineMetricDisplayItem: Identifiable {
  let id: String
  let name: String
  let value: String
  let image: NSImage?
  let valueColor: NSColor?
  let showsLoadingShimmer: Bool
}

@MainActor
private final class InlineMetricsModel: ObservableObject {
  @Published var items: [InlineMetricDisplayItem] = []
  @Published var loadingEffectsActive = false
}

@MainActor
private struct InlineMetricValue: View {
  let item: InlineMetricDisplayItem
  let loadingEffectsActive: Bool

  var body: some View {
    if item.showsLoadingShimmer, loadingEffectsActive {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        let progress =
          timeline.date.timeIntervalSinceReferenceDate
          .truncatingRemainder(dividingBy: 1.1) / 1.1
        valueText
          .foregroundStyle(.secondary.opacity(0.55))
          .overlay {
            GeometryReader { geometry in
              let width = geometry.size.width
              LinearGradient(
                colors: [.clear, .primary, .clear],
                startPoint: .leading,
                endPoint: .trailing
              )
              .frame(width: max(18, width * 0.42))
              .offset(x: -width * 0.42 + width * 1.42 * progress)
            }
          }
          .mask(valueText)
      }
    } else {
      valueText.foregroundStyle(
        item.valueColor.map(Color.init(nsColor:)) ?? Color.primary
      )
    }
  }

  private var valueText: some View {
    Text(item.value)
      .font(.system(size: 12, weight: .semibold))
      .monospacedDigit()
      .lineLimit(1)
      .truncationMode(.middle)
  }
}

@MainActor
private struct InlineMetricCell: View {
  let item: InlineMetricDisplayItem
  let loadingEffectsActive: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      if let image = item.image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(.secondary)
          .frame(width: 14, height: 14)
          .padding(.top, 1)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(item.name.uppercased())
          .font(.system(size: 9, weight: .medium))
          .tracking(0.45)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        InlineMetricValue(
          item: item,
          loadingEffectsActive: loadingEffectsActive
        )
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
  }
}

@MainActor
private struct InlineMetricsContent: View {
  @ObservedObject var model: InlineMetricsModel
  let columnCount: Int

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 12),
      count: columnCount
    )
  }

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
      ForEach(model.items) { item in
        InlineMetricCell(
          item: item,
          loadingEffectsActive: model.loadingEffectsActive
        )
      }
    }
    .padding(.horizontal, MenuViewLayout.horizontalPadding)
    .padding(.vertical, 4)
  }
}

@MainActor
final class InlineMetricsView: NSView {
  private static let rowHeight: CGFloat = 34
  private static let rowSpacing: CGFloat = 6
  private static let verticalPadding: CGFloat = 8

  private let maximumItemCount: Int
  private let viewHeight: CGFloat
  private let model = InlineMetricsModel()

  override var isFlipped: Bool { true }

  init(maximumItemCount: Int, columnCount: Int = 2) {
    self.maximumItemCount = max(1, maximumItemCount)
    let columnCount = max(1, columnCount)
    let rows = Int(ceil(Double(maximumItemCount) / Double(columnCount)))
    self.viewHeight =
      CGFloat(rows) * Self.rowHeight
      + CGFloat(max(0, rows - 1)) * Self.rowSpacing
      + Self.verticalPadding
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: viewHeight
      )
    )

    let hostingView = NSHostingView(
      rootView: InlineMetricsContent(
        model: model,
        columnCount: columnCount
      )
    )
    hostingView.frame = bounds
    hostingView.autoresizingMask = [.width, .height]
    hostingView.setAccessibilityElement(false)
    addSubview(hostingView)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: viewHeight)
  }

  func update(_ proposedItems: [ResourceListItem], animated: Bool = true) {
    model.items = proposedItems.prefix(maximumItemCount).map { item in
      InlineMetricDisplayItem(
        id: item.identifier,
        name: item.name,
        value: item.value,
        image: item.image,
        valueColor: item.valueColor,
        showsLoadingShimmer: item.showsLoadingShimmer
      )
    }
  }

  func setLoadingEffectsActive(_ active: Bool) {
    model.loadingEffectsActive = active
  }
}

@MainActor
final class ResourceRowView: NSView {
  static let height: CGFloat = 30

  private static let placeholderImage: NSImage? = {
    let image =
      NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
    image?.isTemplate = true
    return image
  }()

  private let iconView = NSImageView()
  private let nameField = NSTextField(labelWithString: "")
  private let valueField = NSTextField(labelWithString: "")

  override var isFlipped: Bool { true }

  init(
    name: String = "",
    value: String = "",
    image: NSImage? = nil,
    accessibilityLabel: String? = nil,
    valueColor: NSColor? = nil
  ) {
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: Self.height
      )
    )

    iconView.imageScaling = .scaleProportionallyDown
    iconView.contentTintColor = .secondaryLabelColor
    iconView.setAccessibilityElement(false)

    nameField.font = .systemFont(ofSize: 13, weight: .regular)
    nameField.textColor = .labelColor
    nameField.lineBreakMode = .byTruncatingTail
    nameField.setAccessibilityElement(false)

    valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    valueField.textColor = valueColor ?? .secondaryLabelColor
    valueField.alignment = .right
    valueField.lineBreakMode = .byTruncatingHead
    valueField.setAccessibilityElement(false)

    addSubview(iconView)
    addSubview(nameField)
    addSubview(valueField)

    setAccessibilityRole(.staticText)
    if name.isEmpty, value.isEmpty {
      clear()
    } else {
      update(
        name: name,
        value: value,
        image: image,
        accessibilityLabel: accessibilityLabel,
        valueColor: valueColor
      )
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: Self.height)
  }

  override func layout() {
    super.layout()

    let padding = MenuViewLayout.horizontalPadding
    let iconLeading = padding
    let nameLeading = iconLeading + MenuViewLayout.iconSize + MenuViewLayout.textGap
    let measuredValueWidth = ceil(valueField.intrinsicContentSize.width) + 6
    let valueWidth = min(166, max(52, measuredValueWidth))
    let valueLeading = bounds.width - padding - valueWidth

    iconView.frame = NSRect(
      x: iconLeading,
      y: 6,
      width: MenuViewLayout.iconSize,
      height: MenuViewLayout.iconSize
    )
    nameField.frame = NSRect(
      x: nameLeading,
      y: 5,
      width: max(0, valueLeading - nameLeading - 10),
      height: 20
    )
    valueField.frame = NSRect(
      x: valueLeading,
      y: 5,
      width: valueWidth,
      height: 20
    )
  }

  func update(
    name: String,
    value: String,
    image: NSImage?,
    accessibilityLabel: String? = nil,
    valueColor: NSColor? = nil
  ) {
    let rowImage = image ?? Self.placeholderImage
    if iconView.image !== rowImage {
      iconView.image = rowImage
    }
    if nameField.stringValue != name {
      nameField.stringValue = name
      nameField.toolTip = name.isEmpty ? nil : name
    }
    if valueField.stringValue != value {
      valueField.stringValue = value
      needsLayout = true
    }
    valueField.textColor = valueColor ?? .secondaryLabelColor
    valueField.isHidden = false
    isHidden = false
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(accessibilityLabel ?? name)
    setAccessibilityValue(value)
  }

  func clear() {
    iconView.image = nil
    nameField.stringValue = ""
    nameField.toolTip = nil
    valueField.stringValue = ""
    isHidden = true
    setAccessibilityElement(false)
  }
}

struct ResourceListItem {
  let identifier: String
  let name: String
  let value: String
  let image: NSImage?
  let accessibilityLabel: String
  let showsLoadingShimmer: Bool
  let valueColor: NSColor?

  init(
    identifier: String,
    name: String,
    value: String,
    image: NSImage?,
    accessibilityLabel: String,
    showsLoadingShimmer: Bool = false,
    valueColor: NSColor? = nil
  ) {
    self.identifier = identifier
    self.name = name
    self.value = value
    self.image = image
    self.accessibilityLabel = accessibilityLabel
    self.showsLoadingShimmer = showsLoadingShimmer
    self.valueColor = valueColor
  }
}

@MainActor
final class ResourceListView: NSView {
  private static let animationDuration = 0.18
  private static let horizontalTravel: CGFloat = 14

  private let maximumItemCount: Int
  private let reservesMaximumHeight: Bool
  private var listHeight: CGFloat
  private var activeRows: [String: ResourceRowView] = [:]
  private var orderedIdentifiers: [String] = []
  private var retiringRows: [ResourceRowView] = []
  private var animationsActive = false

  override var isFlipped: Bool { true }

  init(
    maximumItemCount: Int = 15,
    reservesMaximumHeight: Bool = true
  ) {
    self.maximumItemCount = max(1, maximumItemCount)
    self.reservesMaximumHeight = reservesMaximumHeight
    self.listHeight =
      ResourceRowView.height
      * CGFloat(reservesMaximumHeight ? max(1, maximumItemCount) : 1)
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: listHeight
      )
    )
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: listHeight)
  }

  func update(_ proposedItems: [ResourceListItem], animated: Bool = true) {
    let items = Array(proposedItems.prefix(maximumItemCount))
    updateListHeight(itemCount: items.count)
    removeRetiringRows()

    let shouldAnimate =
      animated
      && animationsActive
      && !orderedIdentifiers.isEmpty
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard shouldAnimate else {
      applyImmediately(items)
      return
    }

    let newIdentifiers = Set(items.map(\.identifier))
    var nextRows: [String: ResourceRowView] = [:]
    nextRows.reserveCapacity(items.count)

    for (rank, item) in items.enumerated() {
      let row: ResourceRowView
      if let existing = activeRows[item.identifier] {
        row = existing
      } else {
        row = makeRow(for: item)
        row.frame = frame(forRank: rank).offsetBy(
          dx: Self.horizontalTravel,
          dy: 0
        )
        row.alphaValue = 0
        addSubview(row)
      }
      update(row, with: item)
      nextRows[item.identifier] = row
    }

    for identifier in orderedIdentifiers where !newIdentifiers.contains(identifier) {
      guard let row = activeRows[identifier] else { continue }
      row.setAccessibilityElement(false)
      retiringRows.append(row)
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

      for row in retiringRows {
        row.animator().frame = row.frame.offsetBy(
          dx: -Self.horizontalTravel,
          dy: 0
        )
        row.animator().alphaValue = 0
      }

      for (rank, item) in items.enumerated() {
        guard let row = nextRows[item.identifier] else { continue }
        row.animator().frame = frame(forRank: rank)
        row.animator().alphaValue = 1
      }
    }

    activeRows = nextRows
    orderedIdentifiers = items.map(\.identifier)
  }

  private func updateListHeight(itemCount: Int) {
    guard !reservesMaximumHeight else { return }
    let newHeight = ResourceRowView.height * CGFloat(max(1, itemCount))
    guard listHeight != newHeight else { return }

    listHeight = newHeight
    frame.size.height = newHeight
    invalidateIntrinsicContentSize()
  }

  func setAnimationsActive(_ active: Bool) {
    guard animationsActive != active else { return }
    animationsActive = active

    if active {
      wantsLayer = true
      layer?.masksToBounds = true
      return
    }

    layer?.removeAllAnimations()
    removeRetiringRows()
    for (rank, identifier) in orderedIdentifiers.enumerated() {
      guard let row = activeRows[identifier] else { continue }
      row.layer?.removeAllAnimations()
      row.frame = frame(forRank: rank)
      row.alphaValue = 1
    }
    wantsLayer = false
  }

  private func applyImmediately(_ items: [ResourceListItem]) {
    let newIdentifiers = Set(items.map(\.identifier))
    let removedIdentifiers = activeRows.keys.filter {
      !newIdentifiers.contains($0)
    }
    for identifier in removedIdentifiers {
      activeRows.removeValue(forKey: identifier)?.removeFromSuperview()
    }

    var nextRows: [String: ResourceRowView] = [:]
    nextRows.reserveCapacity(items.count)
    for (rank, item) in items.enumerated() {
      let row = activeRows[item.identifier] ?? makeRow(for: item)
      update(row, with: item)
      row.frame = frame(forRank: rank)
      row.alphaValue = 1
      if row.superview == nil {
        addSubview(row)
      }
      nextRows[item.identifier] = row
    }

    activeRows = nextRows
    orderedIdentifiers = items.map(\.identifier)
  }

  private func makeRow(for item: ResourceListItem) -> ResourceRowView {
    ResourceRowView(
      name: item.name,
      value: item.value,
      image: item.image,
      accessibilityLabel: item.accessibilityLabel,
      valueColor: item.valueColor
    )
  }

  private func update(_ row: ResourceRowView, with item: ResourceListItem) {
    row.update(
      name: item.name,
      value: item.value,
      image: item.image,
      accessibilityLabel: item.accessibilityLabel,
      valueColor: item.valueColor
    )
  }

  private func frame(forRank rank: Int) -> NSRect {
    NSRect(
      x: 0,
      y: CGFloat(rank) * ResourceRowView.height,
      width: MenuViewLayout.width,
      height: ResourceRowView.height
    )
  }

  private func removeRetiringRows() {
    for row in retiringRows {
      row.removeFromSuperview()
    }
    retiringRows.removeAll(keepingCapacity: true)
  }
}

@MainActor
final class ResourceListScrollView: NSScrollView {
  private let list: ResourceListView
  private let viewHeight: CGFloat

  init(list: ResourceListView, visibleRowCount: Int = 6) {
    self.list = list
    self.viewHeight = ResourceRowView.height * CGFloat(max(1, visibleRowCount))
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: MenuViewLayout.width,
        height: viewHeight
      )
    )

    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    hasVerticalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay
    verticalScrollElasticity = .automatic
    contentView.drawsBackground = false
    documentView = list
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: MenuViewLayout.width, height: viewHeight)
  }

  override func layout() {
    super.layout()
    list.frame = NSRect(
      x: 0,
      y: 0,
      width: contentSize.width,
      height: max(contentSize.height, list.intrinsicContentSize.height)
    )
  }
}
