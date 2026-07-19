public struct CPUUsageBreakdown: Sendable, Equatable {
  public let userPercent: Double
  public let systemPercent: Double
  public let idlePercent: Double
}

public struct MemoryBreakdown: Sendable, Equatable {
  public let appBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  public let freeBytes: UInt64
  public let pressureLevel: MemoryPressureLevel
}

public enum MemoryPressureLevel: Sendable, Equatable {
  case normal
  case warning
  case critical
  case unavailable
}

public struct NetworkDetails: Sendable, Equatable {
  public let totalReceivedBytes: UInt64
  public let totalSentBytes: UInt64
  public let interfaceName: String?
  public let interfaceType: String?
  public let networkName: String?
  public let localAddress: String?
  public let gatewayAddress: String?
  public let dnsServers: [String]
  public let signalDBm: Int?
  public let channelNumber: Int?
  public let transmitRateMbps: Double?
}

public struct StorageActivity: Sendable, Equatable {
  public let readBytesPerSecond: Double
  public let writeBytesPerSecond: Double

  public init(readBytesPerSecond: Double, writeBytesPerSecond: Double) {
    self.readBytesPerSecond = readBytesPerSecond
    self.writeBytesPerSecond = writeBytesPerSecond
  }
}

public struct StatsSnapshot: Sendable {
  public let cpuPercent: Double
  public let memoryUsed: UInt64
  public let memoryTotal: UInt64
  public let downloadBytesPerSecond: Double
  public let uploadBytesPerSecond: Double
  public let storage: StorageStats?
  public let battery: BatteryStats?
  public let swap: SwapStats?
  public let loadAverages: LoadAverages?
  public let cpuBreakdown: CPUUsageBreakdown?
  public let memoryBreakdown: MemoryBreakdown?
  public let networkDetails: NetworkDetails?
  public let storageActivity: StorageActivity?

  public var memoryPercent: Double {
    guard memoryTotal > 0 else { return 0 }
    return min(100, Double(memoryUsed) / Double(memoryTotal) * 100)
  }

  public init(
    cpuPercent: Double,
    memoryUsed: UInt64,
    memoryTotal: UInt64,
    downloadBytesPerSecond: Double,
    uploadBytesPerSecond: Double,
    storage: StorageStats? = nil,
    battery: BatteryStats? = nil,
    swap: SwapStats? = nil,
    loadAverages: LoadAverages? = nil,
    cpuBreakdown: CPUUsageBreakdown? = nil,
    memoryBreakdown: MemoryBreakdown? = nil,
    networkDetails: NetworkDetails? = nil,
    storageActivity: StorageActivity? = nil
  ) {
    self.cpuPercent = cpuPercent
    self.memoryUsed = memoryUsed
    self.memoryTotal = memoryTotal
    self.downloadBytesPerSecond = downloadBytesPerSecond
    self.uploadBytesPerSecond = uploadBytesPerSecond
    self.storage = storage
    self.battery = battery
    self.swap = swap
    self.loadAverages = loadAverages
    self.cpuBreakdown = cpuBreakdown
    self.memoryBreakdown = memoryBreakdown
    self.networkDetails = networkDetails
    self.storageActivity = storageActivity
  }
}
