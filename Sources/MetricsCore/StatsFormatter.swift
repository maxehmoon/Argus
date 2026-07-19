import Foundation

public enum StatsFormatter {
  public static func percentage(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
  }

  public static func rate(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000_000 {
      return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
    }
    if bytesPerSecond >= 1_000_000 {
      return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
      return "\(Int((bytesPerSecond / 1_000).rounded())) KB/s"
    }
    return "\(Int(bytesPerSecond.rounded())) B/s"
  }

  public static func gigabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / 1_000_000_000)
  }

  public static func memory(_ bytes: UInt64) -> String {
    if bytes >= 1_000_000_000 {
      return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
    if bytes >= 1_000_000 {
      return "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }
    if bytes >= 1_000 {
      return "\(Int((Double(bytes) / 1_000).rounded())) KB"
    }
    return "\(bytes) B"
  }

  public static func compactMemory(_ bytes: UInt64) -> String {
    if bytes >= 1_000_000_000 {
      return String(format: "%.1fG", Double(bytes) / 1_000_000_000)
    }
    if bytes >= 1_000_000 {
      return "\(Int((Double(bytes) / 1_000_000).rounded()))M"
    }
    if bytes >= 1_000 {
      return "\(Int((Double(bytes) / 1_000).rounded()))K"
    }
    return "\(bytes)B"
  }

  public static func loadAverage(_ value: Double) -> String {
    String(format: "%.2f", max(0, value))
  }

  public static func loadAverages(_ values: LoadAverages) -> String {
    [values.oneMinute, values.fiveMinutes, values.fifteenMinutes]
      .map { String(format: "%.1f", max(0, $0)) }
      .joined(separator: " · ")
  }

  public static func temperature(_ celsius: Double) -> String {
    "\(Int(celsius.rounded()))°C"
  }

  public static func frequency(_ megahertz: Int) -> String {
    megahertz >= 1_000
      ? String(format: "%.2f GHz", Double(megahertz) / 1_000)
      : "\(megahertz) MHz"
  }

  public static func uptime(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(seconds) / 60)
    let days = totalMinutes / (24 * 60)
    let hours = totalMinutes / 60 % 24
    let minutes = totalMinutes % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }

  public static func duration(minutes: Int) -> String {
    let minutes = max(0, minutes)
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours > 0 {
      return remainingMinutes > 0
        ? "\(hours)h \(remainingMinutes)m"
        : "\(hours)h"
    }
    return "\(minutes)m"
  }

  public static func countryFlag(countryCode: String) -> String? {
    let scalars = countryCode.uppercased().unicodeScalars
    guard scalars.count == 2 else { return nil }

    let regionalIndicators = scalars.compactMap { scalar -> UnicodeScalar? in
      guard scalar.value >= 65, scalar.value <= 90 else { return nil }
      return UnicodeScalar(127_397 + scalar.value)
    }
    guard regionalIndicators.count == 2 else { return nil }
    return String(String.UnicodeScalarView(regionalIndicators))
  }
}
