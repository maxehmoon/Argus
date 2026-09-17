import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

public struct SystemSampleOptions: OptionSet, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let cpu = Self(rawValue: 1 << 0)
  public static let memory = Self(rawValue: 1 << 1)
  public static let network = Self(rawValue: 1 << 2)
  public static let storage = Self(rawValue: 1 << 3)
  public static let battery = Self(rawValue: 1 << 4)
  public static let swap = Self(rawValue: 1 << 5)
  public static let load = Self(rawValue: 1 << 6)
  public static let all: Self = [
    .cpu, .memory, .network, .storage, .battery, .swap, .load,
  ]
}

public struct StorageStats: Sendable, Equatable {
  public let volumeName: String?
  public let totalBytes: UInt64
  public let freeBytes: UInt64
  public let reclaimableBytes: UInt64?

  public var usedBytes: UInt64 {
    totalBytes - min(totalBytes, freeBytes)
  }

  public var usedPercent: Double {
    guard totalBytes > 0 else { return 0 }
    return min(100, Double(usedBytes) / Double(totalBytes) * 100)
  }

  public init(
    volumeName: String? = nil,
    totalBytes: UInt64,
    freeBytes: UInt64,
    reclaimableBytes: UInt64?
  ) {
    self.volumeName = volumeName
    self.totalBytes = totalBytes
    self.freeBytes = freeBytes
    self.reclaimableBytes = reclaimableBytes
  }
}

public enum BatteryState: Sendable, Equatable {
  case charging
  case full
  case pluggedIn
  case onBattery
}

public struct BatteryStats: Sendable, Equatable {
  public let chargePercent: Double
  public let state: BatteryState
  public let minutesRemaining: Int?
  public let isPluggedIn: Bool
  public let powerWatts: Double?
  public let maximumCapacityPercent: Double?
  public let cycleCount: Int?
}

public struct SwapStats: Sendable, Equatable {
  public let usedBytes: UInt64
  public let totalBytes: UInt64

  public var availableBytes: UInt64 {
    totalBytes - min(totalBytes, usedBytes)
  }
}

public struct LoadAverages: Sendable, Equatable {
  public let oneMinute: Double
  public let fiveMinutes: Double
  public let fifteenMinutes: Double
}

public enum SystemCapabilities {
  public static let hasBattery = BatteryReader.sample() != nil
}

final class AdditionalStatsSampler {
  private static let slowSampleLifetime = Duration.seconds(30)

  private var cachedStorage: TimedValue<StorageStats?>?
  private var cachedBattery: TimedValue<BatteryStats?>?
  private var cachedNetworkIdentity: TimedValue<NetworkIdentity?>?

  func storage() -> StorageStats? {
    cachedValue(&cachedStorage, sample: Self.sampleStorage)
  }

  func battery() -> BatteryStats? {
    cachedValue(&cachedBattery, sample: BatteryReader.sample)
  }

  func invalidateBattery() {
    cachedBattery = nil
  }

  func invalidateNetworkIdentity() {
    cachedNetworkIdentity = nil
  }

  func networkIdentity() -> NetworkIdentity? {
    cachedValue(&cachedNetworkIdentity, sample: Self.sampleNetworkIdentity)
  }

  func swap() -> SwapStats? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
      return nil
    }
    return SwapStats(
      usedBytes: usage.xsu_used,
      totalBytes: usage.xsu_total
    )
  }

  func loadAverages() -> LoadAverages? {
    var values = [Double](repeating: 0, count: 3)
    let count = values.withUnsafeMutableBufferPointer { buffer in
      getloadavg(buffer.baseAddress, Int32(buffer.count))
    }
    guard count == values.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      return nil
    }
    return LoadAverages(
      oneMinute: values[0],
      fiveMinutes: values[1],
      fifteenMinutes: values[2]
    )
  }

  private func cachedValue<Value>(
    _ cache: inout TimedValue<Value>?,
    sample: () -> Value
  ) -> Value {
    let now = ContinuousClock.now
    if let cache,
      cache.capturedAt.duration(to: now) < Self.slowSampleLifetime
    {
      return cache.value
    }

    let value = sample()
    cache = TimedValue(value: value, capturedAt: now)
    return value
  }

  private static func sampleStorage() -> StorageStats? {
    let keys: Set<URLResourceKey> = [
      .volumeNameKey,
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
    ]
    guard
      let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
      let total = values.volumeTotalCapacity,
      let free = values.volumeAvailableCapacity,
      total > 0,
      free >= 0
    else { return nil }

    let reclaimable = values.volumeAvailableCapacityForImportantUsage.map {
      UInt64(max(0, $0))
    }
    return StorageStats(
      volumeName: values.volumeName,
      totalBytes: UInt64(total),
      freeBytes: UInt64(free),
      reclaimableBytes: reclaimable
    )
  }

  private static func sampleNetworkIdentity() -> NetworkIdentity? {
    let ipv4 =
      SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    let ipv6 =
      SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
    guard let route = primaryNetworkRoute(ipv4: ipv4, ipv6: ipv6) else { return nil }
    let primaryInterface = route.interface
    let primaryService = route.service
    let gatewayAddress = route.gateway

    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return nil }
    defer { freeifaddrs(head) }

    var ipv4Address: String?
    var ipv6Address: String?
    var current: UnsafeMutablePointer<ifaddrs>? = head
    while let interface = current {
      let value = interface.pointee
      if String(cString: value.ifa_name) == primaryInterface,
        let socketAddress = value.ifa_addr,
        (socketAddress.pointee.sa_family == UInt8(AF_INET)
          || socketAddress.pointee.sa_family == UInt8(AF_INET6))
      {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
          socketAddress,
          socklen_t(socketAddress.pointee.sa_len),
          &host,
          socklen_t(host.count),
          nil,
          0,
          NI_NUMERICHOST
        ) == 0 {
          let address = String(
            decoding: host.prefix(while: { $0 != 0 }).map {
              UInt8(bitPattern: $0)
            },
            as: UTF8.self
          )
          if socketAddress.pointee.sa_family == UInt8(AF_INET) {
            ipv4Address = address
          } else if ipv6Address == nil || !address.hasPrefix("fe80:") {
            ipv6Address = address
          }
        }
      }
      current = value.ifa_next
    }

    let wifiInterface = CWWiFiClient.shared().interface(withName: primaryInterface)
    let networkInterface = systemInterface(named: primaryInterface)
    let transmitRate = wifiInterface?.transmitRate()
    return NetworkIdentity(
      name: primaryInterface,
      type: wifiInterface == nil
        ? networkInterface.flatMap(localizedInterfaceName)
        : "Wi-Fi",
      networkName: wifiInterface?.ssid(),
      localAddress: ipv4Address ?? ipv6Address,
      ipv6Address: ipv6Address,
      gatewayAddress: gatewayAddress,
      dnsServers: dnsServers(primaryService: primaryService),
      signalDBm: wifiInterface.map { $0.rssiValue() },
      channelNumber: wifiInterface?.wlanChannel()?.channelNumber,
      transmitRateMbps: transmitRate.flatMap { $0 > 0 ? $0 : nil }
    )
  }

  private static func systemInterface(named name: String) -> SCNetworkInterface? {
    guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]
    else { return nil }
    return interfaces.first {
      (SCNetworkInterfaceGetBSDName($0) as String?) == name
    }
  }

  private static func localizedInterfaceName(
    _ interface: SCNetworkInterface
  ) -> String? {
    SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
  }

  private static func dnsServers(primaryService: String?) -> [String] {
    let keys = [
      primaryService.map { "State:/Network/Service/\($0)/DNS" },
      "State:/Network/Global/DNS",
    ].compactMap { $0 }

    for key in keys {
      if let values = SCDynamicStoreCopyValue(nil, key as CFString)
        as? [String: Any],
        let servers = values["ServerAddresses"] as? [String],
        !servers.isEmpty
      {
        return servers
      }
    }
    return []
  }
}

struct NetworkIdentity {
  let name: String
  let type: String?
  let networkName: String?
  let localAddress: String?
  let ipv6Address: String?
  let gatewayAddress: String?
  let dnsServers: [String]
  let signalDBm: Int?
  let channelNumber: Int?
  let transmitRateMbps: Double?
}

private struct TimedValue<Value> {
  let value: Value
  let capturedAt: ContinuousClock.Instant
}

enum BatteryReader {
  static func sample() -> BatteryStats? {
    guard
      let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }

    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?
          .takeUnretainedValue() as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        description[kIOPSIsPresentKey] as? Bool != false,
        description[kIOPSMaxCapacityKey] as? Int != nil
      else { continue }

      return decode(description, hardware: hardwareDetails())
    }
    return nil
  }

  static func decode(_ description: [String: Any], hardware: BatteryHardwareDetails = .init())
    -> BatteryStats?
  {
    guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
    else { return nil }
    let isCharging = description[kIOPSIsChargingKey] as? Bool == true
    let powerSource = description[kIOPSPowerSourceStateKey] as? String
    let isPluggedIn = powerSource == kIOPSACPowerValue
    let chargePercent = min(
      100,
      max(0, Double(currentCapacity) / Double(maximum) * 100)
    )
    let state: BatteryState
    if isPluggedIn && isCharging {
      state = .charging
    } else if isPluggedIn && description[kIOPSIsChargedKey] as? Bool == true {
      state = .full
    } else if isPluggedIn {
      state = .pluggedIn
    } else {
      state = .onBattery
    }

    let timeKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
    let rawMinutes = description[timeKey] as? Int
    let hardwareMinutes =
      isCharging
      ? hardware.averageMinutesToFull
      : hardware.averageMinutesToEmpty
    let minutesRemaining = validMinutes(rawMinutes) ?? validMinutes(hardwareMinutes)
    let voltage =
      positiveNumber(description[kIOPSVoltageKey])
      ?? hardware.voltageMillivolts
    let currentMilliamps =
      number(description[kIOPSCurrentKey])
      ?? hardware.currentMilliamps
    let powerWatts = voltage.flatMap { voltage in
      currentMilliamps.map { current in
        abs(Double(voltage) * Double(current)) / 1_000_000
      }
    }
    let maximumCapacityPercent: Double?
    if let full = hardware.fullChargeCapacity,
      let design = hardware.designCapacity,
      design > 0
    {
      maximumCapacityPercent = min(
        100,
        max(0, Double(full) / Double(design) * 100)
      )
    } else {
      maximumCapacityPercent = nil
    }
    return BatteryStats(
      chargePercent: chargePercent,
      state: state,
      minutesRemaining: minutesRemaining,
      isPluggedIn: isPluggedIn,
      powerWatts: powerWatts,
      maximumCapacityPercent: maximumCapacityPercent,
      cycleCount: hardware.cycleCount
    )
  }

  private static func hardwareDetails() -> BatteryHardwareDetails {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("AppleSmartBattery")
    )
    guard service != IO_OBJECT_NULL else { return BatteryHardwareDetails() }
    defer { IOObjectRelease(service) }

    var properties: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(
        service,
        &properties,
        kCFAllocatorDefault,
        0
      ) == KERN_SUCCESS,
      let values = properties?.takeRetainedValue() as? [String: Any]
    else { return BatteryHardwareDetails() }

    let batteryData = values["BatteryData"] as? [String: Any]
    return BatteryHardwareDetails(
      voltageMillivolts: positiveNumber(values["Voltage"]),
      currentMilliamps: number(values["InstantAmperage"])
        ?? number(values["Amperage"]),
      fullChargeCapacity: number(batteryData?["FullChargeCapacity"])
        ?? number(batteryData?["AppleRawMaxCapacity"]),
      designCapacity: number(batteryData?["DesignCapacity"]),
      cycleCount: number(values["CycleCount"])
        ?? number(batteryData?["CycleCount"]),
      averageMinutesToEmpty: number(values["AvgTimeToEmpty"])
        ?? number(values["TimeRemaining"])
        ?? number(batteryData?["AvgTimeToEmpty"]),
      averageMinutesToFull: number(values["AvgTimeToFull"])
        ?? number(batteryData?["AvgTimeToFull"])
    )
  }

  private static func validMinutes(_ value: Int?) -> Int? {
    guard let value, value >= 0, value < 65_535 else { return nil }
    return value
  }

  private static func number(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  private static func positiveNumber(_ value: Any?) -> Int? {
    guard let value = number(value), value > 0 else { return nil }
    return value
  }


}

struct BatteryHardwareDetails {
  var voltageMillivolts: Int?
  var currentMilliamps: Int?
  var fullChargeCapacity: Int?
  var designCapacity: Int?
  var cycleCount: Int?
  var averageMinutesToEmpty: Int?
  var averageMinutesToFull: Int?
}

struct NetworkRoute: Equatable {
  let interface: String
  let service: String?
  let gateway: String?
}

func primaryNetworkRoute(ipv4: [String: Any]?, ipv6: [String: Any]?) -> NetworkRoute? {
  for values in [ipv4, ipv6] {
    guard let values, let interface = values["PrimaryInterface"] as? String else { continue }
    return NetworkRoute(
      interface: interface,
      service: values["PrimaryService"] as? String,
      gateway: values["Router"] as? String
    )
  }
  return nil
}
