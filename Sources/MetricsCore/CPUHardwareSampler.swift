import Darwin
import Foundation
import IOKit

public struct CPUHardwareStats: Sendable, Equatable {
  public let temperatureCelsius: Double?
  public let frequencyMHz: Int?

  public init(temperatureCelsius: Double?, frequencyMHz: Int?) {
    self.temperatureCelsius = temperatureCelsius
    self.frequencyMHz = frequencyMHz
  }
}

public actor CPUHardwareSampler {
  private let temperatureReader = SMCTemperatureReader()
  private let frequencyReader = IOReportFrequencyReader()

  public init() {}

  public func sample() async -> CPUHardwareStats {
    let temperature = temperatureReader.read()
    let frequency = await frequencyReader.read()
    return CPUHardwareStats(
      temperatureCelsius: temperature,
      frequencyMHz: frequency
    )
  }
}

private typealias SMCBytes = (
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyData {
  struct KeyInfo {
    var dataSize: IOByteCount32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
  }

  var key: UInt32 = 0
  var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
  var powerLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
  var keyInfo = KeyInfo()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  )
}

private final class SMCTemperatureReader {
  private static let candidateKeys = [
    "TCMz",
    "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X",
    "Tp0b", "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
    "TC10", "TC11", "TC12", "TC13", "TC20", "TC21", "TC22", "TC23",
    "TC30", "TC31", "TC32", "TC33", "TC40", "TC41", "TC42", "TC43",
    "TC50", "TC51", "TC52", "TC53",
    "Te05", "Te0L", "Te0P", "Te0S", "Te09", "Te0H",
    "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A",
    "Tf4B", "Tf4D", "Tf4E",
    "Tp0V", "Tp0Y", "Tp0e",
  ]

  private var connection: io_connect_t = 0
  private var availableKeys: [String]?

  init() {
    guard let matching = IOServiceMatching("AppleSMC") else { return }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }
    guard
      IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    else {
      connection = 0
      return
    }
  }

  deinit {
    if connection != 0 {
      IOServiceClose(connection)
    }
  }

  func read() -> Double? {
    guard connection != 0 else { return nil }

    let keys = availableKeys ?? Self.candidateKeys
    var validKeys: [String] = []
    var highestTemperature: Double?

    for key in keys {
      guard let value = readTemperature(key) else { continue }
      validKeys.append(key)
      highestTemperature = max(highestTemperature ?? value, value)
    }

    if availableKeys == nil {
      availableKeys = validKeys
    }
    return highestTemperature
  }

  private func readTemperature(_ key: String) -> Double? {
    guard key.utf8.count == 4 else { return nil }

    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    input.data8 = 9

    guard call(input: &input, output: &output) == kIOReturnSuccess else {
      return nil
    }
    guard output.keyInfo.dataSize == 4 else { return nil }

    input.keyInfo.dataSize = output.keyInfo.dataSize
    input.data8 = 5
    guard call(input: &input, output: &output) == kIOReturnSuccess else {
      return nil
    }

    let bits =
      UInt32(output.bytes.0)
      | (UInt32(output.bytes.1) << 8)
      | (UInt32(output.bytes.2) << 16)
      | (UInt32(output.bytes.3) << 24)
    let value = Double(Float(bitPattern: bits))
    return value.isFinite && value > 10 && value < 150 ? value : nil
  }

  private func call(
    input: inout SMCKeyData,
    output: inout SMCKeyData
  ) -> kern_return_t {
    var outputSize = MemoryLayout<SMCKeyData>.stride
    return IOConnectCallStructMethod(
      connection,
      2,
      &input,
      MemoryLayout<SMCKeyData>.stride,
      &output,
      &outputSize
    )
  }
}

private actor IOReportFrequencyReader {
  private let api: IOReportAPI?
  private let channels: CFMutableDictionary?
  private let subscription: IOReportSubscription?
  private let efficiencyFrequencies: [Int]
  private let performanceFrequencies: [Int]

  init() {
    let frequencyTables = Self.loadFrequencyTables()
    efficiencyFrequencies = frequencyTables.efficiency
    performanceFrequencies = frequencyTables.performance

    guard
      let api = IOReportAPI(),
      let copiedChannels = api.copyChannels(
        "CPU Stats" as CFString,
        nil,
        0,
        0,
        0
      )?.takeRetainedValue(),
      let mutableChannels = CFDictionaryCreateMutableCopy(
        kCFAllocatorDefault,
        0,
        copiedChannels
      )
    else {
      self.api = nil
      channels = nil
      subscription = nil
      return
    }

    var subsystem: Unmanaged<CFMutableDictionary>?
    let rawSubscription = api.createSubscription(
      nil,
      mutableChannels,
      &subsystem,
      0,
      nil
    )
    subsystem?.release()

    self.api = api
    channels = mutableChannels
    subscription = rawSubscription.map { IOReportSubscription(pointer: $0) }
  }

  func read() async -> Int? {
    guard
      let api,
      let channels,
      let subscription,
      let first = api.createSamples(
        subscription.pointer,
        channels,
        nil
      )?.takeRetainedValue()
    else { return nil }

    do {
      try await Task.sleep(for: .milliseconds(100))
    } catch {
      return nil
    }

    guard
      let second = api.createSamples(
        subscription.pointer,
        channels,
        nil
      )?.takeRetainedValue(),
      let delta = api.createSamplesDelta(
        first,
        second,
        nil
      )?.takeRetainedValue()
    else { return nil }

    return frequency(from: delta, api: api)
  }

  private func frequency(
    from delta: CFDictionary,
    api: IOReportAPI
  ) -> Int? {
    let key = "IOReportChannels" as CFString
    guard
      let rawChannels = CFDictionaryGetValue(
        delta,
        Unmanaged.passUnretained(key).toOpaque()
      )
    else { return nil }

    let channelsValue = unsafeBitCast(rawChannels, to: CFTypeRef.self)
    guard CFGetTypeID(channelsValue) == CFArrayGetTypeID() else { return nil }
    let reportChannels = unsafeDowncast(channelsValue, to: CFArray.self)
    var totalActiveTime: Int64 = 0
    var totalWeightedFrequency = 0.0

    for index in 0..<CFArrayGetCount(reportChannels) {
      let rawChannel = CFArrayGetValueAtIndex(reportChannels, index)
      let channelValue = unsafeBitCast(rawChannel, to: CFTypeRef.self)
      guard CFGetTypeID(channelValue) == CFDictionaryGetTypeID() else {
        continue
      }
      let channel = unsafeDowncast(channelValue, to: CFDictionary.self)

      guard
        api.string(from: api.channelGroup(channel)) == "CPU Stats",
        let channelName = api.string(from: api.channelName(channel))
      else { continue }

      let subgroup = api.string(from: api.channelSubgroup(channel)) ?? ""
      guard subgroup == "CPU Complex Performance States" else { continue }

      let isEfficiency = channelName.contains("ECPU") || channelName == "CPU0"
      let isPerformance = channelName.contains("PCPU") || channelName == "CPU1"
      guard isEfficiency || isPerformance else { continue }

      let frequencies =
        isEfficiency
        ? efficiencyFrequencies
        : performanceFrequencies
      let stateCount = api.stateCount(channel)
      guard stateCount > 0, stateCount <= 512 else { continue }

      for stateIndex in 0..<stateCount {
        guard
          let stateName = api.string(
            from: api.stateName(channel, stateIndex)
          ),
          stateName != "OFF",
          stateName != "IDLE",
          stateName.first == "V",
          let frequencyIndex = Int(
            stateName.dropFirst().prefix(while: \Character.isNumber)
          ),
          frequencies.indices.contains(frequencyIndex)
        else { continue }

        let residency = api.stateResidency(channel, stateIndex)
        guard residency > 0 else { continue }
        totalActiveTime += residency
        totalWeightedFrequency += Double(frequencies[frequencyIndex]) * Double(residency)
      }
    }

    guard totalActiveTime > 0 else { return nil }
    return Int((totalWeightedFrequency / Double(totalActiveTime)).rounded())
  }

  private static func loadFrequencyTables() -> (
    efficiency: [Int],
    performance: [Int]
  ) {
    let entry = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceNameMatching("pmgr")
    )
    guard entry != 0 else { return ([], []) }
    defer { IOObjectRelease(entry) }

    var properties: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(
        entry,
        &properties,
        kCFAllocatorDefault,
        0
      ) == kIOReturnSuccess,
      let dictionary = properties?.takeRetainedValue() as NSDictionary?
    else { return ([], []) }

    let efficiency = frequencies(
      from: dictionary["voltage-states1-sram"] as? Data
        ?? dictionary["voltage-states9-sram"] as? Data
    )
    let performance = frequencies(
      from: dictionary["voltage-states5-sram"] as? Data
        ?? dictionary["voltage-states3-sram"] as? Data
    )
    return (efficiency, performance)
  }

  private static func frequencies(from data: Data?) -> [Int] {
    guard let data else { return [] }
    return data.withUnsafeBytes { bytes in
      stride(from: 0, to: data.count - (data.count % 8), by: 8).compactMap {
        offset in
        let raw = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        if raw >= 100_000_000 { return Int(raw / 1_000_000) }
        if raw >= 100_000 { return Int(raw / 1_000) }
        return nil
      }
    }
  }
}

private final class IOReportSubscription: @unchecked Sendable {
  let pointer: OpaquePointer

  init(pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    Unmanaged<CFTypeRef>
      .fromOpaque(UnsafeRawPointer(pointer))
      .release()
  }
}

private final class IOReportAPI {
  typealias CopyChannels =
    @convention(c) (
      CFString, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFDictionary>?
  typealias CreateSubscription =
    @convention(c) (
      UnsafeMutableRawPointer?, CFMutableDictionary,
      UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64,
      UnsafeMutableRawPointer?
    ) -> OpaquePointer?
  typealias CreateSamples =
    @convention(c) (
      OpaquePointer, CFDictionary, UnsafeMutableRawPointer?
    ) -> Unmanaged<CFDictionary>?
  typealias CreateSamplesDelta =
    @convention(c) (
      CFDictionary, CFDictionary, UnsafeMutableRawPointer?
    ) -> Unmanaged<CFDictionary>?
  typealias ChannelString =
    @convention(c) (
      CFDictionary
    ) -> Unmanaged<CFString>?
  typealias StateCount = @convention(c) (CFDictionary) -> Int32
  typealias StateName =
    @convention(c) (
      CFDictionary, Int32
    ) -> Unmanaged<CFString>?
  typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

  let copyChannels: CopyChannels
  let createSubscription: CreateSubscription
  let createSamples: CreateSamples
  let createSamplesDelta: CreateSamplesDelta
  let channelName: ChannelString
  let channelGroup: ChannelString
  let channelSubgroup: ChannelString
  let stateCount: StateCount
  let stateName: StateName
  let stateResidency: StateResidency
  private let handle: UnsafeMutableRawPointer

  init?() {
    guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
      return nil
    }
    guard
      let copyChannels: CopyChannels = Self.load(
        "IOReportCopyChannelsInGroup",
        from: handle
      ),
      let createSubscription: CreateSubscription = Self.load(
        "IOReportCreateSubscription",
        from: handle
      ),
      let createSamples: CreateSamples = Self.load(
        "IOReportCreateSamples",
        from: handle
      ),
      let createSamplesDelta: CreateSamplesDelta = Self.load(
        "IOReportCreateSamplesDelta",
        from: handle
      ),
      let channelName: ChannelString = Self.load(
        "IOReportChannelGetChannelName",
        from: handle
      ),
      let channelGroup: ChannelString = Self.load(
        "IOReportChannelGetGroup",
        from: handle
      ),
      let channelSubgroup: ChannelString = Self.load(
        "IOReportChannelGetSubGroup",
        from: handle
      ),
      let stateCount: StateCount = Self.load(
        "IOReportStateGetCount",
        from: handle
      ),
      let stateName: StateName = Self.load(
        "IOReportStateGetNameForIndex",
        from: handle
      ),
      let stateResidency: StateResidency = Self.load(
        "IOReportStateGetResidency",
        from: handle
      )
    else {
      dlclose(handle)
      return nil
    }

    self.copyChannels = copyChannels
    self.createSubscription = createSubscription
    self.createSamples = createSamples
    self.createSamplesDelta = createSamplesDelta
    self.channelName = channelName
    self.channelGroup = channelGroup
    self.channelSubgroup = channelSubgroup
    self.stateCount = stateCount
    self.stateName = stateName
    self.stateResidency = stateResidency
    self.handle = handle
  }

  deinit {
    dlclose(handle)
  }

  func string(from value: Unmanaged<CFString>?) -> String? {
    value?.takeUnretainedValue() as String?
  }

  private static func load<Function>(
    _ name: String,
    from handle: UnsafeMutableRawPointer
  ) -> Function? {
    guard let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: Function.self)
  }
}
