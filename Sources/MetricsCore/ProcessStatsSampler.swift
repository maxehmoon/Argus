import Darwin
import Foundation

public struct AppCPUUsage: Sendable, Equatable {
  public let name: String
  public let bundlePath: String?
  public let percent: Double

  public init(name: String, bundlePath: String?, percent: Double) {
    self.name = name
    self.bundlePath = bundlePath
    self.percent = percent
  }
}

public struct AppMemoryUsage: Sendable, Equatable {
  public let name: String
  public let bundlePath: String?
  public let bytes: UInt64

  public init(name: String, bundlePath: String?, bytes: UInt64) {
    self.name = name
    self.bundlePath = bundlePath
    self.bytes = bytes
  }
}

public struct AppEnergyUsage: Sendable, Equatable {
  public let name: String
  public let bundlePath: String?
  public let watts: Double

  public init(name: String, bundlePath: String?, watts: Double) {
    self.name = name
    self.bundlePath = bundlePath
    self.watts = watts
  }
}

public struct AppStorageUsage: Sendable, Equatable {
  public let name: String
  public let bundlePath: String?
  public let readBytesPerSecond: Double
  public let writeBytesPerSecond: Double

  public init(
    name: String,
    bundlePath: String?,
    readBytesPerSecond: Double,
    writeBytesPerSecond: Double
  ) {
    self.name = name
    self.bundlePath = bundlePath
    self.readBytesPerSecond = readBytesPerSecond
    self.writeBytesPerSecond = writeBytesPerSecond
  }
}

public actor ProcessStatsSampler {
  private var cachedCPUSample:
    (
      batch: ProcessSampleBatch,
      capturedAt: ContinuousClock.Instant
    )?
  private var cachedStorageSample:
    (
      batch: ProcessSampleBatch,
      capturedAt: ContinuousClock.Instant
    )?

  public init() {}

  public func topCPUApplications(limit: Int = 5) async -> [AppCPUUsage] {
    guard limit > 0 else { return [] }

    let now = ContinuousClock.now
    let first: ProcessSampleBatch
    if let cachedCPUSample,
      cachedCPUSample.capturedAt.duration(to: now) < .milliseconds(250)
    {
      first = cachedCPUSample.batch
    } else {
      first = await Task.detached(priority: .utility) {
        Self.captureProcesses()
      }.value
    }
    cachedCPUSample = (first, ContinuousClock.now)

    do {
      try await Task.sleep(for: .seconds(1))
    } catch {
      return []
    }

    let second = await Task.detached(priority: .utility) {
      Self.captureProcesses()
    }.value
    cachedCPUSample = (second, ContinuousClock.now)
    guard !Task.isCancelled else { return [] }

    return await Task.detached(priority: .utility) {
      rankCPUApplications(previous: first, current: second, limit: limit)
    }.value
  }

  public func topMemoryApplications(limit: Int = 5) async -> [AppMemoryUsage] {
    guard limit > 0 else { return [] }

    return await Task.detached(priority: .utility) {
      rankMemoryApplications(samples: Self.captureProcesses().samples, limit: limit)
    }.value
  }

  public func topEnergyApplications(limit: Int = 5) async -> [AppEnergyUsage] {
    guard limit > 0 else { return [] }

    let first = await Task.detached(priority: .utility) {
      Self.captureProcesses()
    }.value
    do {
      try await Task.sleep(for: .seconds(1))
    } catch {
      return []
    }

    let second = await Task.detached(priority: .utility) {
      Self.captureProcesses()
    }.value
    guard !Task.isCancelled else { return [] }

    return await Task.detached(priority: .utility) {
      rankEnergyApplications(previous: first, current: second, limit: limit)
    }.value
  }

  public func topStorageApplications(limit: Int = 5) async -> [AppStorageUsage] {
    guard limit > 0 else { return [] }

    let now = ContinuousClock.now
    let first: ProcessSampleBatch
    if let cachedStorageSample,
      cachedStorageSample.capturedAt.duration(to: now) < .milliseconds(250)
    {
      first = cachedStorageSample.batch
    } else {
      first = await Task.detached(priority: .utility) {
        Self.captureProcesses()
      }.value
    }
    cachedStorageSample = (first, ContinuousClock.now)

    do {
      try await Task.sleep(for: .seconds(1))
    } catch {
      return []
    }

    let second = await Task.detached(priority: .utility) {
      Self.captureProcesses()
    }.value
    cachedStorageSample = (second, ContinuousClock.now)
    guard !Task.isCancelled else { return [] }

    return await Task.detached(priority: .utility) {
      rankStorageApplications(previous: first, current: second, limit: limit)
    }.value
  }

  private static func captureProcesses() -> ProcessSampleBatch {
    let estimatedBytes = max(
      0,
      Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0))
    )
    let estimatedCount = estimatedBytes / MemoryLayout<pid_t>.stride
    guard estimatedCount > 0 else {
      return ProcessSampleBatch(
        timestamp: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
        samples: [:]
      )
    }

    var pids = [pid_t](repeating: 0, count: estimatedCount + 64)
    let bytesWritten = pids.withUnsafeMutableBytes { buffer in
      proc_listpids(
        UInt32(PROC_ALL_PIDS),
        0,
        buffer.baseAddress,
        Int32(buffer.count)
      )
    }
    let count = max(0, Int(bytesWritten) / MemoryLayout<pid_t>.stride)
    let timestamp = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    var samples: [pid_t: RawProcessSample] = [:]
    samples.reserveCapacity(count)

    for pid in pids.prefix(count) where pid > 0 {
      guard let sample = processSample(pid: pid) else { continue }
      samples[pid] = sample
    }

    return ProcessSampleBatch(timestamp: timestamp, samples: samples)
  }

  private static func processSample(pid: pid_t) -> RawProcessSample? {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
      }
    }
    guard result == 0 else { return nil }

    let (cpuTime, overflow) = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
    guard !overflow else { return nil }

    return RawProcessSample(
      pid: pid,
      startTime: info.ri_proc_start_abstime,
      cpuTime: cpuTime,
      footprint: info.ri_phys_footprint,
      energyNanojoules: info.ri_energy_nj,
      diskReadBytes: info.ri_diskio_bytesread,
      diskWriteBytes: info.ri_diskio_byteswritten
    )
  }
}

struct RawProcessSample: Sendable, Equatable {
  let pid: pid_t
  let startTime: UInt64
  let cpuTime: UInt64
  let footprint: UInt64
  let energyNanojoules: UInt64
  let diskReadBytes: UInt64
  let diskWriteBytes: UInt64

  init(
    pid: pid_t,
    startTime: UInt64,
    cpuTime: UInt64,
    footprint: UInt64,
    energyNanojoules: UInt64 = 0,
    diskReadBytes: UInt64 = 0,
    diskWriteBytes: UInt64 = 0
  ) {
    self.pid = pid
    self.startTime = startTime
    self.cpuTime = cpuTime
    self.footprint = footprint
    self.energyNanojoules = energyNanojoules
    self.diskReadBytes = diskReadBytes
    self.diskWriteBytes = diskWriteBytes
  }
}

struct ProcessSampleBatch: Sendable, Equatable {
  let timestamp: UInt64
  let samples: [pid_t: RawProcessSample]
}

struct ProcessIdentity: Sendable, Equatable {
  let name: String
  let bundlePath: String?

  var aggregationKey: String {
    bundlePath ?? "process:\(name)"
  }
}

enum ProcessIdentityResolver {
  static func resolve(pid: pid_t) -> ProcessIdentity? {
    if let executablePath = executablePath(pid: pid) {
      if let bundlePath = outermostApplicationPath(in: executablePath) {
        let name = URL(fileURLWithPath: bundlePath)
          .deletingPathExtension()
          .lastPathComponent
        return ProcessIdentity(name: name, bundlePath: bundlePath)
      }

      let name = URL(fileURLWithPath: executablePath).lastPathComponent
      if !name.isEmpty {
        return ProcessIdentity(name: name, bundlePath: nil)
      }
    }

    guard let name = processName(pid: pid), !name.isEmpty else { return nil }
    return ProcessIdentity(name: name, bundlePath: nil)
  }

  static func outermostApplicationPath(in executablePath: String) -> String? {
    guard let marker = executablePath.range(of: ".app/", options: .caseInsensitive) else {
      return nil
    }
    let end = executablePath.index(marker.lowerBound, offsetBy: 4)
    return String(executablePath[..<end])
  }

  private static func executablePath(pid: pid_t) -> String? {
    withUnsafeTemporaryAllocation(
      of: CChar.self,
      capacity: 4 * 1_024
    ) { buffer in
      guard
        let baseAddress = buffer.baseAddress,
        proc_pidpath(pid, baseAddress, UInt32(buffer.count)) > 0
      else {
        return nil
      }
      return String(cString: baseAddress)
    }
  }

  private static func processName(pid: pid_t) -> String? {
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 256) { buffer in
      guard
        let baseAddress = buffer.baseAddress,
        proc_name(pid, baseAddress, UInt32(buffer.count)) > 0
      else {
        return nil
      }
      return String(cString: baseAddress)
    }
  }
}

func rankCPUApplications(
  previous: ProcessSampleBatch,
  current: ProcessSampleBatch,
  limit: Int,
  resolveIdentity: (pid_t) -> ProcessIdentity? = ProcessIdentityResolver.resolve
) -> [AppCPUUsage] {
  guard current.timestamp > previous.timestamp, limit > 0 else { return [] }
  let elapsed = current.timestamp - previous.timestamp
  var totals: [String: (identity: ProcessIdentity, cpuTime: UInt64)] = [:]

  for (pid, sample) in current.samples {
    guard
      let prior = previous.samples[pid],
      prior.startTime == sample.startTime,
      sample.cpuTime >= prior.cpuTime
    else {
      continue
    }

    let delta = sample.cpuTime - prior.cpuTime
    guard delta > 0, let identity = resolveIdentity(pid) else { continue }
    let existing = totals[identity.aggregationKey]?.cpuTime ?? 0
    totals[identity.aggregationKey] = (identity, existing &+ delta)
  }

  return totals.values
    .map { value in
      AppCPUUsage(
        name: value.identity.name,
        bundlePath: value.identity.bundlePath,
        percent: Double(value.cpuTime) / Double(elapsed) * 100
      )
    }
    .sorted { lhs, rhs in
      if lhs.percent == rhs.percent { return lhs.name < rhs.name }
      return lhs.percent > rhs.percent
    }
    .prefix(limit)
    .map(\.self)
}

func rankMemoryApplications(
  samples: [pid_t: RawProcessSample],
  limit: Int,
  resolveIdentity: (pid_t) -> ProcessIdentity? = ProcessIdentityResolver.resolve
) -> [AppMemoryUsage] {
  guard limit > 0 else { return [] }
  var totals: [String: (identity: ProcessIdentity, footprint: UInt64)] = [:]

  for (pid, sample) in samples where sample.footprint > 0 {
    guard let identity = resolveIdentity(pid) else { continue }
    let existing = totals[identity.aggregationKey]?.footprint ?? 0
    totals[identity.aggregationKey] = (identity, existing &+ sample.footprint)
  }

  return totals.values
    .map { value in
      AppMemoryUsage(
        name: value.identity.name,
        bundlePath: value.identity.bundlePath,
        bytes: value.footprint
      )
    }
    .sorted { lhs, rhs in
      if lhs.bytes == rhs.bytes { return lhs.name < rhs.name }
      return lhs.bytes > rhs.bytes
    }
    .prefix(limit)
    .map(\.self)
}

func rankEnergyApplications(
  previous: ProcessSampleBatch,
  current: ProcessSampleBatch,
  limit: Int,
  resolveIdentity: (pid_t) -> ProcessIdentity? = ProcessIdentityResolver.resolve
) -> [AppEnergyUsage] {
  guard current.timestamp > previous.timestamp, limit > 0 else { return [] }
  let elapsedNanoseconds = current.timestamp - previous.timestamp
  var totals: [String: (identity: ProcessIdentity, energy: UInt64)] = [:]

  for (pid, sample) in current.samples {
    guard
      let prior = previous.samples[pid],
      prior.startTime == sample.startTime,
      sample.energyNanojoules >= prior.energyNanojoules
    else { continue }

    let delta = sample.energyNanojoules - prior.energyNanojoules
    guard delta > 0, let identity = resolveIdentity(pid) else { continue }
    let existing = totals[identity.aggregationKey]?.energy ?? 0
    totals[identity.aggregationKey] = (identity, existing &+ delta)
  }

  return totals.values
    .map { value in
      AppEnergyUsage(
        name: value.identity.name,
        bundlePath: value.identity.bundlePath,
        watts: Double(value.energy) / Double(elapsedNanoseconds)
      )
    }
    .sorted { lhs, rhs in
      if lhs.watts == rhs.watts { return lhs.name < rhs.name }
      return lhs.watts > rhs.watts
    }
    .prefix(limit)
    .map(\.self)
}

func rankStorageApplications(
  previous: ProcessSampleBatch,
  current: ProcessSampleBatch,
  limit: Int,
  resolveIdentity: (pid_t) -> ProcessIdentity? = ProcessIdentityResolver.resolve
) -> [AppStorageUsage] {
  guard current.timestamp > previous.timestamp, limit > 0 else { return [] }
  let elapsedNanoseconds = current.timestamp - previous.timestamp
  var totals: [String: (identity: ProcessIdentity, read: UInt64, written: UInt64)] =
    [:]

  for (pid, sample) in current.samples {
    guard
      let prior = previous.samples[pid],
      prior.startTime == sample.startTime,
      sample.diskReadBytes >= prior.diskReadBytes,
      sample.diskWriteBytes >= prior.diskWriteBytes
    else { continue }

    let read = sample.diskReadBytes - prior.diskReadBytes
    let written = sample.diskWriteBytes - prior.diskWriteBytes
    guard read > 0 || written > 0 else { continue }
    guard let identity = resolveIdentity(pid) else { continue }

    let existing = totals[identity.aggregationKey]
    totals[identity.aggregationKey] = (
      identity,
      (existing?.read ?? 0) &+ read,
      (existing?.written ?? 0) &+ written
    )
  }

  let seconds = Double(elapsedNanoseconds) / 1_000_000_000
  return totals.values
    .map { value in
      AppStorageUsage(
        name: value.identity.name,
        bundlePath: value.identity.bundlePath,
        readBytesPerSecond: Double(value.read) / seconds,
        writeBytesPerSecond: Double(value.written) / seconds
      )
    }
    .sorted { lhs, rhs in
      let lhsTotal = lhs.readBytesPerSecond + lhs.writeBytesPerSecond
      let rhsTotal = rhs.readBytesPerSecond + rhs.writeBytesPerSecond
      if lhsTotal == rhsTotal { return lhs.name < rhs.name }
      return lhsTotal > rhsTotal
    }
    .prefix(limit)
    .map(\.self)
}
