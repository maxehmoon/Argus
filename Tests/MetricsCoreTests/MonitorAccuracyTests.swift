import Darwin
import Foundation
import IOKit.ps
import Testing

@testable import MetricsCore

@Suite("Monitor accuracy regressions")
struct MonitorAccuracyTests {
  @Test func convertsMachTicksBeforeCalculatingCPU() throws {
    let previous = batch(time: 1_000_000_000, cpu: 7_000_000)
    let current = batch(time: 2_000_000_000, cpu: 31_000_000)
    let usage = rankCPUApplications(
      previous: previous, current: current, limit: 1,
      timebase: MachTimebase(numerator: 125, denominator: 3)
    ) { _ in ProcessIdentity(name: "Busy", bundlePath: nil) }
    // 24 million ticks at 125/3 ns per tick = one fully occupied CPU.
    #expect(try #require(usage.first).percent == 100)
  }

  @Test func rejectsStaleOrReversedProcessIntervals() {
    let previous = batch(time: 20_000_000_000)
    #expect(!validProcessInterval(previous: previous, current: batch(time: 19_000_000_000)))
    #expect(!validProcessInterval(previous: previous, current: previous))
    #expect(!validProcessInterval(previous: previous, current: batch(time: 31_000_000_000)))
  }

  @Test func distinguishesUnsupportedEnergyFromIdle() {
    #expect(!hasCPUEnergyCounters(previous: batch(time: 1), current: batch(time: 2)))
    let previous = batch(time: 1, energy: 500)
    let current = batch(time: 2, energy: 500)
    #expect(hasCPUEnergyCounters(previous: previous, current: current))
    #expect(rankEnergyApplications(previous: previous, current: current, limit: 5).isEmpty)
  }

  @Test func deviceRemovalDoesNotEraseAnotherDevicesActivity() {
    var rates = CounterRateSampler<Int>()
    #expect(
      rates.sample(
        [
          1: IOCounters(first: 1_000, second: 2_000),
          2: IOCounters(first: 10_000, second: 20_000),
        ], at: 1) == nil)
    #expect(
      rates.sample([1: IOCounters(first: 1_100, second: 2_200)], at: 2)
        == CounterRates(first: 100, second: 200))
  }

  @Test func seedsNewDevicesAndIgnoresResetCounters() {
    var rates = CounterRateSampler<Int>()
    _ = rates.sample([1: IOCounters(first: 100, second: 100)], at: 1)
    #expect(
      rates.sample(
        [
          1: IOCounters(first: 120, second: 140),
          2: IOCounters(first: 50_000, second: 90_000),
        ], at: 2) == CounterRates(first: 20, second: 40))
    #expect(
      rates.sample(
        [
          1: IOCounters(first: 0, second: 0),
          2: IOCounters(first: 50_030, second: 90_040),
        ], at: 3) == CounterRates(first: 30, second: 40))
  }

  @Test func missingWarmupAndStaleRatesAreNotZero() {
    var rates = CounterRateSampler<String>()
    let counters = ["en0": IOCounters(first: 100, second: 200)]
    #expect(rates.sample(counters, at: 1) == nil)
    #expect(rates.sample(counters, at: 2) == CounterRates(first: 0, second: 0))
    #expect(rates.sample(nil, at: 3) == nil)
    #expect(rates.sample(counters, at: 4) == nil)
    #expect(rates.sample(counters, at: 20) == nil)
    #expect(rates.sample(counters, at: 21) == CounterRates(first: 0, second: 0))
    #expect(rates.sample(["utun1": IOCounters(first: 20_000, second: 30_000)], at: 22) == nil)
  }

  @Test func filtersDiskImagesButKeepsInternalAndExternalDisks() {
    #expect(
      isPhysicalStorageDevice([
        "Physical Interconnect": "Apple Fabric", "Physical Interconnect Location": "Internal",
      ]))
    #expect(
      isPhysicalStorageDevice([
        "Physical Interconnect": "USB", "Physical Interconnect Location": "External",
      ]))
    #expect(
      !isPhysicalStorageDevice([
        "Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "File",
      ]))
    #expect(!isPhysicalStorageDevice(nil))
  }

  @Test func selectsOneRoutingLayerAndSupportsIPv6OnlyConnections() {
    let ipv4: [String: Any] = ["PrimaryInterface": "en0", "Router": "192.0.2.1"]
    let ipv6: [String: Any] = ["PrimaryInterface": "en1", "Router": "2001:db8::1"]
    #expect(primaryNetworkRoute(ipv4: nil, ipv6: ipv6)?.interface == "en1")
    #expect(primaryNetworkRoute(ipv4: nil, ipv6: ipv6)?.gateway == "2001:db8::1")
    #expect(primaryNetworkRoute(ipv4: ipv4, ipv6: ipv6)?.interface == "en0")
    #expect(
      primaryNetworkRoute(ipv4: ["PrimaryInterface": "utun1"], ipv6: ipv6)?.interface == "utun1")
    #expect(primaryNetworkRoute(ipv4: nil, ipv6: nil) == nil)
  }

  @Test func usesNativeChargedStateAndExternalPower() throws {
    var values: [String: Any] = [
      kIOPSCurrentCapacityKey: 96, kIOPSMaxCapacityKey: 100,
      kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargedKey: true,
    ]
    #expect(try #require(BatteryReader.decode(values)).state == .full)
    values[kIOPSIsChargedKey] = false
    #expect(try #require(BatteryReader.decode(values)).state == .pluggedIn)
    values[kIOPSIsChargingKey] = true
    #expect(try #require(BatteryReader.decode(values)).state == .charging)
    values[kIOPSCurrentCapacityKey] = 100
    values[kIOPSIsChargedKey] = true
    values[kIOPSIsChargingKey] = false
    values[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
    #expect(try #require(BatteryReader.decode(values)).state == .onBattery)
  }

  @Test func preservesZeroAndSignedBatteryCurrent() throws {
    var values: [String: Any] = [
      kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100, kIOPSVoltageKey: 12_000,
    ]
    #expect(try #require(BatteryReader.decode(values)).powerWatts == nil)
    for current in [-500, 0, 500] {
      values[kIOPSCurrentKey] = current
      let stats = try #require(
        BatteryReader.decode(
          values, hardware: BatteryHardwareDetails(currentMilliamps: 1_000)
        ))
      #expect(stats.powerWatts == abs(Double(current)) * 0.012)
    }
  }

  @Test func excludesUnknownBatteryTimeSentinels() throws {
    let values: [String: Any] = [
      kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100, kIOPSTimeToEmptyKey: -1,
    ]
    #expect(
      try #require(
        BatteryReader.decode(
          values, hardware: BatteryHardwareDetails(averageMinutesToEmpty: 65_535)
        )
      ).minutesRemaining == nil)
  }

  @Test func historyDoesNotInventStartupOrTrailingData() {
    let segments = historySegments(positions: [0.8], values: [20], breaks: [true])
    #expect(segments.count == 1)
    #expect(segments.first?.count == 1)
    #expect(segments.first?.first?.position == 0.8)
  }

  @Test func historyKeepsMissingSamplesAndSleepGaps() {
    let segments = historySegments(
      positions: [0.1, 0.2, 0.3, 0.4, 0.9, 1],
      values: [10, nil, 30, 40, 50, 60],
      breaks: [true, false, false, false, true, false]
    )
    #expect(segments.map { $0.map(\.value) } == [[10], [30, 40], [50, 60]])
    #expect(historyHasGap(elapsed: 20, previousInterval: 5, currentInterval: 1))
    #expect(!historyHasGap(elapsed: 5.5, previousInterval: 1, currentInterval: 5))
  }

  @Test func secondaryHistoryKeepsItsTimestamp() {
    let segments = historySegments(
      positions: [0.1, 0.2, 0.3], values: [1, nil, 3], breaks: [true, false, false]
    )
    #expect(segments.last?.first?.position == 0.3)
    #expect(segments.last?.first?.value == 3)
  }

  @Test func incompleteNetworkOutputIsUnavailable() {
    #expect(NetTopOutputParser.parseFinalDeltaBlock("error") == nil)
    #expect(
      NetTopOutputParser.parseFinalDeltaBlock(",bytes_in,bytes_out,\nApp.1,100,200,\n") == nil)
    #expect(
      NetTopOutputParser.parseFinalDeltaBlock(",bytes_in,bytes_out,\n,bytes_in,bytes_out,\n") == [])
  }

  @Test func malformedNetworkCountersAreUnavailable() {
    #expect(
      NetTopOutputParser.parseFinalDeltaBlock(
        ",bytes_in,bytes_out,\n,bytes_in,bytes_out,\nApp.1,nan,200,\n"
      ) == nil)
  }

  @Test func unavailableFormattingDoesNotLookIdleOrTrap() {
    #expect(StatsFormatter.percentage(nil) == "–")
    #expect(StatsFormatter.percentage(.nan) == "–")
    #expect(StatsFormatter.rate(.infinity) == "–")
    #expect(StatsFormatter.rate(nil) == "–")
    #expect(StatsFormatter.rate(0) == "0 B/s")
  }

  @Test func boundedCommandReadsOutputAndDetectsFailure() {
    let output = BoundedProcess().run(executable: "/usr/bin/printf", arguments: ["sample"])
    #expect(output == Data("sample".utf8))
    #expect(BoundedProcess().run(executable: "/usr/bin/false", arguments: []) == nil)
    #expect(BoundedProcess().run(executable: "/does/not/exist", arguments: []) == nil)
  }

  @Test func stalledCommandTimesOut() async {
    let started = ContinuousClock.now
    let result = await Task.detached {
      BoundedProcess().run(executable: "/bin/sleep", arguments: ["10"], timeout: .milliseconds(150))
    }.value
    #expect(result == nil)
    #expect(started.duration(to: .now) < .seconds(3))
  }

  @Test func cancellationStopsCommandAndPreventsFutureLaunch() async throws {
    let command = BoundedProcess()
    let started = ContinuousClock.now
    let worker = Task.detached { command.run(executable: "/bin/sleep", arguments: ["10"]) }
    try await Task.sleep(for: .milliseconds(100))
    command.cancel()
    #expect(await worker.value == nil)
    #expect(started.duration(to: .now) < .seconds(3))
    #expect(command.run(executable: "/usr/bin/printf", arguments: ["cancelled"]) == nil)
  }

  @Test func excessiveCommandOutputIsBounded() async {
    #expect(
      await Task.detached {
        BoundedProcess().run(executable: "/usr/bin/yes", arguments: [])
      }.value == nil)
  }

  private func batch(time: UInt64, cpu: UInt64 = 0, energy: UInt64 = 0) -> ProcessSampleBatch {
    ProcessSampleBatch(
      timestamp: time,
      samples: [
        10: RawProcessSample(
          pid: 10, startTime: 1, cpuTimeTicks: cpu, footprint: 0, energyNanojoules: energy)
      ])
  }
}
