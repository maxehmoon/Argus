import Darwin
import Foundation
import IOKit

private struct CPUTicks: Equatable {
  let user: UInt32
  let system: UInt32
  let idle: UInt32
  let nice: UInt32
}

private struct InterfaceBytes: Equatable {
  let received: UInt64
  let sent: UInt64
}

private struct StorageBytes: Equatable {
  let read: UInt64
  let written: UInt64
}

private struct CPUSample {
  let percent: Double
  let breakdown: CPUUsageBreakdown?
}

private struct MemorySample {
  let usedBytes: UInt64
  let breakdown: MemoryBreakdown?
}

private struct NetworkSample {
  let rate: InterfaceBytesPerSecond
  let totalReceivedBytes: UInt64
  let totalSentBytes: UInt64
}

public final class SystemStatsSampler {
  private static let minimumRouteBufferSize = 64 * 1_024
  private static let routeBufferHeadroom = 4 * 1_024

  private let hostPort: mach_port_t
  private let pageSize: UInt64
  private let physicalMemory: UInt64
  private let timebaseNumerator: UInt64
  private let timebaseDenominator: UInt64
  private let additionalSampler = AdditionalStatsSampler()

  private var previousCPU: CPUTicks?
  private var previousInterfaces: [UInt16: InterfaceBytes] = [:]
  private var currentInterfaces: [UInt16: InterfaceBytes] = [:]
  private var previousNetworkTime: UInt64?
  private var previousStorageBytes: StorageBytes?
  private var previousStorageTime: UInt64?

  private var routeMIB: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
  private var routeBuffer: UnsafeMutableRawPointer
  private var routeBufferSize: Int

  var sampledNetworkInterfaceCount: Int {
    previousInterfaces.count
  }

  public init() {
    hostPort = mach_host_self()

    var hostPageSize = vm_size_t(getpagesize())
    if host_page_size(hostPort, &hostPageSize) != KERN_SUCCESS {
      hostPageSize = vm_size_t(getpagesize())
    }
    pageSize = UInt64(hostPageSize)
    physicalMemory = ProcessInfo.processInfo.physicalMemory

    var timebase = mach_timebase_info_data_t()
    if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 {
      timebaseNumerator = UInt64(timebase.numer)
      timebaseDenominator = UInt64(timebase.denom)
    } else {
      timebaseNumerator = 1
      timebaseDenominator = 1
    }

    let requestedSize = Self.requiredRouteBufferSize() ?? 0
    routeBufferSize = max(
      Self.minimumRouteBufferSize,
      requestedSize + Self.routeBufferHeadroom
    )
    routeBuffer = UnsafeMutableRawPointer.allocate(
      byteCount: routeBufferSize,
      alignment: MemoryLayout<if_msghdr2>.alignment
    )

    previousInterfaces.reserveCapacity(64)
    currentInterfaces.reserveCapacity(64)
  }

  deinit {
    routeBuffer.deallocate()
    mach_port_deallocate(mach_task_self_, hostPort)
  }

  public func sample(options: SystemSampleOptions = .all) -> StatsSnapshot {
    let now = mach_continuous_time()
    let cpu =
      options.contains(.cpu)
      ? sampleCPU()
      : CPUSample(percent: 0, breakdown: nil)
    let memory =
      options.contains(.memory)
      ? sampleMemory()
      : MemorySample(usedBytes: 0, breakdown: nil)
    let network =
      options.contains(.network)
      ? sampleNetwork(at: now)
      : NetworkSample(
        rate: InterfaceBytesPerSecond(received: 0, sent: 0),
        totalReceivedBytes: 0,
        totalSentBytes: 0
      )
    let networkIdentity =
      options.contains(.network)
      ? additionalSampler.networkIdentity()
      : nil
    let storageActivity =
      options.contains(.storage)
      ? sampleStorageActivity(at: now)
      : nil

    return StatsSnapshot(
      cpuPercent: cpu.percent,
      memoryUsed: memory.usedBytes,
      memoryTotal: physicalMemory,
      downloadBytesPerSecond: network.rate.received,
      uploadBytesPerSecond: network.rate.sent,
      storage: options.contains(.storage) ? additionalSampler.storage() : nil,
      battery: options.contains(.battery) ? additionalSampler.battery() : nil,
      swap: options.contains(.swap) ? additionalSampler.swap() : nil,
      loadAverages: options.contains(.load)
        ? additionalSampler.loadAverages()
        : nil,
      cpuBreakdown: cpu.breakdown,
      memoryBreakdown: memory.breakdown,
      networkDetails: options.contains(.network)
        ? NetworkDetails(
          totalReceivedBytes: network.totalReceivedBytes,
          totalSentBytes: network.totalSentBytes,
          interfaceName: networkIdentity?.name,
          interfaceType: networkIdentity?.type,
          networkName: networkIdentity?.networkName,
          localAddress: networkIdentity?.localAddress,
          gatewayAddress: networkIdentity?.gatewayAddress,
          dnsServers: networkIdentity?.dnsServers ?? [],
          signalDBm: networkIdentity?.signalDBm,
          channelNumber: networkIdentity?.channelNumber,
          transmitRateMbps: networkIdentity?.transmitRateMbps
        )
        : nil,
      storageActivity: storageActivity
    )
  }

  public func invalidateBatteryCache() {
    additionalSampler.invalidateBattery()
  }

  public func invalidateNetworkIdentityCache() {
    additionalSampler.invalidateNetworkIdentity()
  }

  private func sampleCPU() -> CPUSample {
    var load = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &load) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return CPUSample(percent: 0, breakdown: nil)
    }

    let current = CPUTicks(
      user: load.cpu_ticks.0,
      system: load.cpu_ticks.1,
      idle: load.cpu_ticks.2,
      nice: load.cpu_ticks.3
    )
    defer { previousCPU = current }
    guard let previousCPU else {
      return CPUSample(percent: 0, breakdown: nil)
    }

    let user = tickDelta(from: previousCPU.user, to: current.user)
    let system = tickDelta(from: previousCPU.system, to: current.system)
    let idle = tickDelta(from: previousCPU.idle, to: current.idle)
    let nice = tickDelta(from: previousCPU.nice, to: current.nice)
    let total = user + system + idle + nice

    guard total > 0 else {
      return CPUSample(percent: 0, breakdown: nil)
    }
    let userPercent = Double(user + nice) / Double(total) * 100
    let systemPercent = Double(system) / Double(total) * 100
    let idlePercent = Double(idle) / Double(total) * 100
    return CPUSample(
      percent: min(100, userPercent + systemPercent),
      breakdown: CPUUsageBreakdown(
        userPercent: userPercent,
        systemPercent: systemPercent,
        idlePercent: idlePercent
      )
    )
  }

  private func sampleMemory() -> MemorySample {
    var statistics = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return MemorySample(usedBytes: 0, breakdown: nil)
    }

    // Activity Monitor's high-level categories use resident internal pages
    // after subtracting purgeable memory, plus wired and compressed memory.
    // `active_count` alone is not equivalent to "App Memory".
    let internalPages = UInt64(statistics.internal_page_count)
    let purgeablePages = UInt64(statistics.purgeable_count)
    let appPages = internalPages - min(internalPages, purgeablePages)
    let wiredPages = UInt64(statistics.wire_count)
    let compressedPages = UInt64(statistics.compressor_page_count)
    let freePages = UInt64(statistics.free_count)
    let usedPages = appPages + wiredPages + compressedPages
    return MemorySample(
      usedBytes: min(physicalMemory, usedPages * pageSize),
      breakdown: MemoryBreakdown(
        appBytes: appPages * pageSize,
        wiredBytes: wiredPages * pageSize,
        compressedBytes: compressedPages * pageSize,
        freeBytes: freePages * pageSize,
        pressureLevel: sampleMemoryPressureLevel()
      )
    )
  }

  private func sampleMemoryPressureLevel() -> MemoryPressureLevel {
    var rawValue: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard
      sysctlbyname(
        "kern.memorystatus_vm_pressure_level",
        &rawValue,
        &size,
        nil,
        0
      ) == 0
    else { return .unavailable }
    return memoryPressureLevel(rawValue: rawValue)
  }

  private func sampleNetwork(at now: UInt64) -> NetworkSample {
    currentInterfaces.removeAll(keepingCapacity: true)
    guard readCurrentInterfaces() else {
      return NetworkSample(
        rate: InterfaceBytesPerSecond(received: 0, sent: 0),
        totalReceivedBytes: 0,
        totalSentBytes: 0
      )
    }

    let totalReceived = currentInterfaces.values.reduce(0) { $0 + $1.received }
    let totalSent = currentInterfaces.values.reduce(0) { $0 + $1.sent }

    defer {
      swap(&previousInterfaces, &currentInterfaces)
      previousNetworkTime = now
    }

    guard let previousNetworkTime, now > previousNetworkTime else {
      return NetworkSample(
        rate: InterfaceBytesPerSecond(received: 0, sent: 0),
        totalReceivedBytes: totalReceived,
        totalSentBytes: totalSent
      )
    }

    let elapsed =
      Double(now - previousNetworkTime)
      * Double(timebaseNumerator)
      / Double(timebaseDenominator)
      / 1_000_000_000
    guard elapsed <= 10 else {
      return NetworkSample(
        rate: InterfaceBytesPerSecond(received: 0, sent: 0),
        totalReceivedBytes: totalReceived,
        totalSentBytes: totalSent
      )
    }
    var received: UInt64 = 0
    var sent: UInt64 = 0

    for (index, current) in currentInterfaces {
      guard let previous = previousInterfaces[index] else { continue }
      if current.received >= previous.received {
        received += current.received - previous.received
      }
      if current.sent >= previous.sent {
        sent += current.sent - previous.sent
      }
    }

    return NetworkSample(
      rate: InterfaceBytesPerSecond(
        received: Double(received) / elapsed,
        sent: Double(sent) / elapsed
      ),
      totalReceivedBytes: totalReceived,
      totalSentBytes: totalSent
    )
  }

  private func sampleStorageActivity(at now: UInt64) -> StorageActivity {
    guard let current = readStorageBytes() else {
      return StorageActivity(readBytesPerSecond: 0, writeBytesPerSecond: 0)
    }

    defer {
      previousStorageBytes = current
      previousStorageTime = now
    }

    guard
      let previousStorageBytes,
      let previousStorageTime,
      now > previousStorageTime
    else {
      return StorageActivity(readBytesPerSecond: 0, writeBytesPerSecond: 0)
    }

    let elapsed =
      Double(now - previousStorageTime)
      * Double(timebaseNumerator)
      / Double(timebaseDenominator)
      / 1_000_000_000
    guard elapsed > 0, elapsed <= 10 else {
      return StorageActivity(readBytesPerSecond: 0, writeBytesPerSecond: 0)
    }

    let read =
      current.read >= previousStorageBytes.read
      ? current.read - previousStorageBytes.read
      : 0
    let written =
      current.written >= previousStorageBytes.written
      ? current.written - previousStorageBytes.written
      : 0
    return StorageActivity(
      readBytesPerSecond: Double(read) / elapsed,
      writeBytesPerSecond: Double(written) / elapsed
    )
  }

  private func readStorageBytes() -> StorageBytes? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOBlockStorageDriver"),
        &iterator
      ) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0
    var foundStatistics = false
    var service = IOIteratorNext(iterator)

    while service != 0 {
      defer {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
      }

      guard
        let property = IORegistryEntryCreateCFProperty(
          service,
          "Statistics" as CFString,
          kCFAllocatorDefault,
          0
        )?.takeRetainedValue() as? [String: Any],
        let bytesRead = property["Bytes (Read)"] as? NSNumber,
        let bytesWritten = property["Bytes (Write)"] as? NSNumber
      else { continue }

      totalRead &+= bytesRead.uint64Value
      totalWritten &+= bytesWritten.uint64Value
      foundStatistics = true
    }

    guard foundStatistics else { return nil }
    return StorageBytes(read: totalRead, written: totalWritten)
  }

  private func readCurrentInterfaces() -> Bool {
    for attempt in 0..<2 {
      var length = routeBufferSize
      let result = routeMIB.withUnsafeMutableBufferPointer { mib in
        sysctl(
          mib.baseAddress,
          u_int(mib.count),
          routeBuffer,
          &length,
          nil,
          0
        )
      }

      if result == 0 {
        return parseRouteMessages(length: length)
      }
      guard errno == ENOMEM, attempt == 0, resizeRouteBuffer() else {
        return false
      }
    }
    return false
  }

  private func parseRouteMessages(length: Int) -> Bool {
    var offset = 0
    while offset < length {
      guard length - offset >= 4 else { return false }

      let message = routeBuffer.advanced(by: offset)
      let messageLength = Int(message.load(as: UInt16.self))
      let messageType = message.load(fromByteOffset: 3, as: UInt8.self)

      guard messageLength >= 4, messageLength <= length - offset else {
        return false
      }

      if Int32(messageType) == RTM_IFINFO2,
        messageLength >= MemoryLayout<if_msghdr2>.size
      {
        let info = message.assumingMemoryBound(to: if_msghdr2.self).pointee
        let isLoopback = (info.ifm_flags & IFF_LOOPBACK) != 0

        if !isLoopback {
          currentInterfaces[info.ifm_index] = InterfaceBytes(
            received: info.ifm_data.ifi_ibytes,
            sent: info.ifm_data.ifi_obytes
          )
        }
      }

      offset += messageLength
    }

    return offset == length
  }

  private func resizeRouteBuffer() -> Bool {
    guard let requiredSize = Self.requiredRouteBufferSize() else { return false }
    let newSize = max(routeBufferSize * 2, requiredSize + Self.routeBufferHeadroom)

    routeBuffer.deallocate()
    routeBufferSize = newSize
    routeBuffer = UnsafeMutableRawPointer.allocate(
      byteCount: newSize,
      alignment: MemoryLayout<if_msghdr2>.alignment
    )
    return true
  }

  private static func requiredRouteBufferSize() -> Int? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size = 0
    let result = mib.withUnsafeMutableBufferPointer {
      sysctl($0.baseAddress, u_int($0.count), nil, &size, nil, 0)
    }
    return result == 0 ? size : nil
  }
}

private struct InterfaceBytesPerSecond {
  let received: Double
  let sent: Double
}

func tickDelta(from previous: UInt32, to current: UInt32) -> UInt64 {
  if current >= previous {
    return UInt64(current - previous)
  }
  return UInt64(UInt32.max - previous) + UInt64(current) + 1
}

func memoryPressureLevel(rawValue: Int32) -> MemoryPressureLevel {
  switch rawValue {
  case 1: .normal
  case 2: .warning
  case 4: .critical
  default: .unavailable
  }
}
