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
  private var cachedSample: (batch: ProcessSampleBatch, capturedAt: ContinuousClock.Instant)?

  public init() {}

  public func topCPUApplications(limit: Int = 5) async -> [AppCPUUsage]? {
    guard limit > 0 else { return [] }
    guard let (first, second) = await samplePair() else { return nil }
    return await Task.detached(priority: .utility) {
      rankCPUApplications(previous: first, current: second, limit: limit)
    }.value
  }

  public func topMemoryApplications(limit: Int = 5) async -> [AppMemoryUsage]? {
    guard limit > 0 else { return [] }
    guard !Task.isCancelled else { return nil }
    return await Task.detached(priority: .utility) {
      Self.captureProcesses().map { rankMemoryApplications(samples: $0.samples, limit: limit) }
    }.value
  }

  public func topEnergyApplications(limit: Int = 5) async -> [AppEnergyUsage]? {
    guard limit > 0 else { return [] }
    guard let (first, second) = await samplePair(),
      hasCPUEnergyCounters(previous: first, current: second)
    else { return nil }
    return await Task.detached(priority: .utility) {
      rankEnergyApplications(previous: first, current: second, limit: limit)
    }.value
  }

  public func topStorageApplications(limit: Int = 5) async -> [AppStorageUsage]? {
    guard limit > 0 else { return [] }
    guard let (first, second) = await samplePair() else { return nil }
    return await Task.detached(priority: .utility) {
      rankStorageApplications(previous: first, current: second, limit: limit)
    }.value
  }

  // Consecutive panels reuse the last batch; CPU, disk and CPU energy all come
  // from the same rusage read. Never reuse a batch across a pause or cancellation.
  private func samplePair() async -> (ProcessSampleBatch, ProcessSampleBatch)? {
    guard !Task.isCancelled else { return nil }
    let started = ContinuousClock.now
    let first: ProcessSampleBatch?
    if let cachedSample,
      cachedSample.capturedAt.duration(to: .now) < .milliseconds(250)
    {
      first = cachedSample.batch
    } else {
      first = await Task.detached(priority: .utility) { Self.captureProcesses() }.value
    }
    cachedSample = nil
    do {
      try await Task.sleep(for: .seconds(1))
    } catch {
      return nil
    }
    guard let first, !Task.isCancelled else { return nil }
    let second = await Task.detached(priority: .utility) { Self.captureProcesses() }.value
    guard !Task.isCancelled, let second,
      started.duration(to: .now) <= .seconds(10),
      validProcessInterval(previous: first, current: second)
    else { return nil }
    cachedSample = (second, .now)
    return (first, second)
  }

  private static func captureProcesses() -> ProcessSampleBatch? {
    let estimatedBytes = max(
      0,
      Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0))
    )
    let estimatedCount = estimatedBytes / MemoryLayout<pid_t>.stride
    guard estimatedCount > 0 else {
      return nil
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

    return samples.isEmpty ? nil : ProcessSampleBatch(timestamp: timestamp, samples: samples)
  }

  private static func processSample(pid: pid_t) -> RawProcessSample? {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
      }
    }
    guard result == 0 else { return nil }

    let (cpuTimeTicks, overflow) = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
    guard !overflow else { return nil }

    return RawProcessSample(
      pid: pid,
      startTime: info.ri_proc_start_abstime,
      cpuTimeTicks: cpuTimeTicks,
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
  let cpuTimeTicks: UInt64
  let footprint: UInt64
  let energyNanojoules: UInt64
  let diskReadBytes: UInt64
  let diskWriteBytes: UInt64

  init(
    pid: pid_t,
    startTime: UInt64,
    cpuTimeTicks: UInt64,
    footprint: UInt64,
    energyNanojoules: UInt64 = 0,
    diskReadBytes: UInt64 = 0,
    diskWriteBytes: UInt64 = 0
  ) {
    self.pid = pid
    self.startTime = startTime
    self.cpuTimeTicks = cpuTimeTicks
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
  timebase: MachTimebase = .system,
  resolveIdentity: (pid_t) -> ProcessIdentity? = ProcessIdentityResolver.resolve
) -> [AppCPUUsage] {
  guard validProcessInterval(previous: previous, current: current), limit > 0 else { return [] }
  let elapsed = current.timestamp - previous.timestamp
  var totals: [String: (identity: ProcessIdentity, cpuTimeTicks: UInt64)] = [:]

  for (pid, sample) in current.samples {
    guard
      let prior = previous.samples[pid],
      prior.startTime == sample.startTime,
      sample.cpuTimeTicks >= prior.cpuTimeTicks
    else {
      continue
    }

    let delta = sample.cpuTimeTicks - prior.cpuTimeTicks
    guard delta > 0, let identity = resolveIdentity(pid) else { continue }
    let existing = totals[identity.aggregationKey]?.cpuTimeTicks ?? 0
    totals[identity.aggregationKey] = (identity, existing &+ delta)
  }

  return totals.values
    .map { value in
      AppCPUUsage(
        name: value.identity.name,
        bundlePath: value.identity.bundlePath,
        percent: timebase.nanoseconds(for: value.cpuTimeTicks) / Double(elapsed) * 100
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
  guard validProcessInterval(previous: previous, current: current), limit > 0 else { return [] }
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
  guard validProcessInterval(previous: previous, current: current), limit > 0 else { return [] }
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

struct MachTimebase: Sendable {
  let numerator: UInt32
  let denominator: UInt32

  static let system: Self = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Self(numerator: info.numer, denominator: info.denom)
  }()

  func nanoseconds(for ticks: UInt64) -> Double {
    Double(ticks) * Double(numerator) / Double(denominator)
  }
}

func validProcessInterval(previous: ProcessSampleBatch, current: ProcessSampleBatch) -> Bool {
  current.timestamp > previous.timestamp
    && current.timestamp - previous.timestamp <= 10_000_000_000
}

func hasCPUEnergyCounters(previous: ProcessSampleBatch, current: ProcessSampleBatch) -> Bool {
  // Unsupported kernels (including Intel) return zero for every lifetime counter.
  // An unchanged, non-zero counter is a valid idle sample.
  previous.samples.values.contains { $0.energyNanojoules > 0 }
    || current.samples.values.contains { $0.energyNanojoules > 0 }
}
