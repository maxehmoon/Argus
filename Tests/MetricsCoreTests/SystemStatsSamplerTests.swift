import Testing

@testable import MetricsCore

@Suite("Native system sampler")
struct SystemStatsSamplerTests {
  @Test
  func returnsPlausibleHostValues() throws {
    let sampler = SystemStatsSampler()
    let sample = sampler.sample()

    #expect(sample.cpuPercent == nil)  // A rate needs two samples.
    #expect(sample.memoryTotal > 0)
    let memoryUsed = try #require(sample.memoryUsed)
    #expect(memoryUsed <= sample.memoryTotal)
    if let memory = sample.memoryBreakdown {
      #expect(memory.appBytes <= sample.memoryTotal)
      #expect(memory.wiredBytes <= sample.memoryTotal)
      #expect(memory.compressedBytes <= sample.memoryTotal)
      #expect(memory.freeBytes <= sample.memoryTotal)
      #expect(
        sample.memoryUsed
          == min(
            sample.memoryTotal,
            memory.appBytes + memory.wiredBytes + memory.compressedBytes
          )
      )
    }
    #expect(sample.downloadBytesPerSecond == nil)
    #expect(sample.uploadBytesPerSecond == nil)
    #expect(sampler.sampledNetworkInterfaceCount <= 1)
  }

  @Test
  func samplesLightweightOptionalStats() {
    let sampler = SystemStatsSampler()
    let sample = sampler.sample(options: [.storage, .swap, .load, .battery])

    #expect(sample.cpuPercent == nil)
    #expect(sample.memoryUsed == nil)
    #expect(sample.downloadBytesPerSecond == nil)
    #expect(sample.uploadBytesPerSecond == nil)
    #expect(sample.storage?.totalBytes ?? 0 > 0)
    #expect(sample.storage?.freeBytes ?? 0 <= sample.storage?.totalBytes ?? 0)
    #expect(sample.storageActivity == nil)  // Seed physical-device counters first.
    #expect(sample.swap != nil)
    #expect(sample.loadAverages?.oneMinute ?? -1 >= 0)
    if let battery = sample.battery {
      #expect((0...100).contains(battery.chargePercent))
    }
  }

  @Test
  func calculatesStorageAndSwapDerivedValues() {
    let storage = StorageStats(
      totalBytes: 100,
      freeBytes: 35,
      reclaimableBytes: 50
    )
    #expect(storage.usedBytes == 65)
    #expect(storage.usedPercent == 65)

    let swap = SwapStats(usedBytes: 30, totalBytes: 100)
    #expect(swap.availableBytes == 70)
  }

  @Test
  func handlesCPUCounterRollover() {
    #expect(tickDelta(from: 100, to: 140) == 40)
    #expect(tickDelta(from: UInt32.max - 10, to: 9) == 20)
  }

  @Test
  func mapsNativeMemoryPressureLevels() {
    #expect(memoryPressureLevel(rawValue: 1) == .normal)
    #expect(memoryPressureLevel(rawValue: 2) == .warning)
    #expect(memoryPressureLevel(rawValue: 4) == .critical)
    #expect(memoryPressureLevel(rawValue: 0) == .unavailable)
  }

  @Test
  func ranksAndAggregatesApplicationCPU() {
    let previous = ProcessSampleBatch(
      timestamp: 1_000,
      samples: [
        10: RawProcessSample(pid: 10, startTime: 1, cpuTimeTicks: 100, footprint: 0),
        11: RawProcessSample(pid: 11, startTime: 2, cpuTimeTicks: 200, footprint: 0),
        12: RawProcessSample(pid: 12, startTime: 3, cpuTimeTicks: 300, footprint: 0),
        13: RawProcessSample(pid: 13, startTime: 4, cpuTimeTicks: 400, footprint: 0),
      ]
    )
    let current = ProcessSampleBatch(
      timestamp: 1_100,
      samples: [
        10: RawProcessSample(pid: 10, startTime: 1, cpuTimeTicks: 120, footprint: 0),
        11: RawProcessSample(pid: 11, startTime: 2, cpuTimeTicks: 230, footprint: 0),
        12: RawProcessSample(pid: 12, startTime: 99, cpuTimeTicks: 900, footprint: 0),
        13: RawProcessSample(pid: 13, startTime: 4, cpuTimeTicks: 440, footprint: 0),
      ]
    )

    let usages = rankCPUApplications(
      previous: previous,
      current: current,
      limit: 5,
      timebase: MachTimebase(numerator: 1, denominator: 1)
    ) { pid in
      switch pid {
      case 10, 11:
        ProcessIdentity(name: "Browser", bundlePath: "/Applications/Browser.app")
      case 13:
        ProcessIdentity(name: "Editor", bundlePath: "/Applications/Editor.app")
      default:
        ProcessIdentity(name: "Reused", bundlePath: nil)
      }
    }

    #expect(
      usages == [
        AppCPUUsage(
          name: "Browser",
          bundlePath: "/Applications/Browser.app",
          percent: 50
        ),
        AppCPUUsage(
          name: "Editor",
          bundlePath: "/Applications/Editor.app",
          percent: 40
        ),
      ]
    )
  }

  @Test
  func ranksAndAggregatesApplicationMemory() {
    let samples: [Int32: RawProcessSample] = [
      10: RawProcessSample(pid: 10, startTime: 1, cpuTimeTicks: 0, footprint: 300),
      11: RawProcessSample(pid: 11, startTime: 2, cpuTimeTicks: 0, footprint: 500),
      12: RawProcessSample(pid: 12, startTime: 3, cpuTimeTicks: 0, footprint: 700),
    ]

    let usages = rankMemoryApplications(samples: samples, limit: 2) { pid in
      if pid == 12 {
        return ProcessIdentity(name: "Editor", bundlePath: "/Applications/Editor.app")
      }
      return ProcessIdentity(name: "Browser", bundlePath: "/Applications/Browser.app")
    }

    #expect(
      usages == [
        AppMemoryUsage(
          name: "Browser",
          bundlePath: "/Applications/Browser.app",
          bytes: 800
        ),
        AppMemoryUsage(
          name: "Editor",
          bundlePath: "/Applications/Editor.app",
          bytes: 700
        ),
      ]
    )
  }

  @Test
  func ranksAndAggregatesApplicationEnergy() {
    let previous = ProcessSampleBatch(
      timestamp: 1_000_000_000,
      samples: [
        10: RawProcessSample(
          pid: 10,
          startTime: 1,
          cpuTimeTicks: 0,
          footprint: 0,
          energyNanojoules: 100
        ),
        11: RawProcessSample(
          pid: 11,
          startTime: 2,
          cpuTimeTicks: 0,
          footprint: 0,
          energyNanojoules: 200
        ),
        12: RawProcessSample(
          pid: 12,
          startTime: 3,
          cpuTimeTicks: 0,
          footprint: 0,
          energyNanojoules: 300
        ),
      ]
    )
    let current = ProcessSampleBatch(
      timestamp: 2_000_000_000,
      samples: [
        10: RawProcessSample(
          pid: 10,
          startTime: 1,
          cpuTimeTicks: 0,
          footprint: 0,
          energyNanojoules: 2_000_000_100
        ),
        11: RawProcessSample(
          pid: 11,
          startTime: 2,
          cpuTimeTicks: 0,
          footprint: 0,
          energyNanojoules: 1_000_000_200
        ),
        12: RawProcessSample(
          pid: 12,
          startTime: 3,
          cpuTimeTicks: 0,
          footprint: 0,
          energyNanojoules: 500_000_300
        ),
      ]
    )

    let usages = rankEnergyApplications(
      previous: previous,
      current: current,
      limit: 5
    ) { pid in
      if pid == 12 {
        return ProcessIdentity(name: "Editor", bundlePath: "/Applications/Editor.app")
      }
      return ProcessIdentity(name: "Browser", bundlePath: "/Applications/Browser.app")
    }

    #expect(
      usages == [
        AppEnergyUsage(
          name: "Browser",
          bundlePath: "/Applications/Browser.app",
          watts: 3
        ),
        AppEnergyUsage(
          name: "Editor",
          bundlePath: "/Applications/Editor.app",
          watts: 0.5
        ),
      ]
    )
  }

  @Test
  func ranksAndAggregatesApplicationStorageActivity() {
    let previous = ProcessSampleBatch(
      timestamp: 1_000_000_000,
      samples: [
        10: RawProcessSample(
          pid: 10,
          startTime: 1,
          cpuTimeTicks: 0,
          footprint: 0,
          diskReadBytes: 100,
          diskWriteBytes: 100
        ),
        11: RawProcessSample(
          pid: 11,
          startTime: 2,
          cpuTimeTicks: 0,
          footprint: 0,
          diskReadBytes: 100,
          diskWriteBytes: 100
        ),
        12: RawProcessSample(
          pid: 12,
          startTime: 3,
          cpuTimeTicks: 0,
          footprint: 0,
          diskReadBytes: 100,
          diskWriteBytes: 100
        ),
      ]
    )
    let current = ProcessSampleBatch(
      timestamp: 2_000_000_000,
      samples: [
        10: RawProcessSample(
          pid: 10,
          startTime: 1,
          cpuTimeTicks: 0,
          footprint: 0,
          diskReadBytes: 1_100,
          diskWriteBytes: 2_100
        ),
        11: RawProcessSample(
          pid: 11,
          startTime: 2,
          cpuTimeTicks: 0,
          footprint: 0,
          diskReadBytes: 3_100,
          diskWriteBytes: 1_100
        ),
        12: RawProcessSample(
          pid: 12,
          startTime: 3,
          cpuTimeTicks: 0,
          footprint: 0,
          diskReadBytes: 600,
          diskWriteBytes: 500
        ),
      ]
    )

    let usages = rankStorageApplications(
      previous: previous,
      current: current,
      limit: 5
    ) { pid in
      if pid == 12 {
        return ProcessIdentity(name: "Editor", bundlePath: "/Applications/Editor.app")
      }
      return ProcessIdentity(name: "Browser", bundlePath: "/Applications/Browser.app")
    }

    #expect(
      usages == [
        AppStorageUsage(
          name: "Browser",
          bundlePath: "/Applications/Browser.app",
          readBytesPerSecond: 4_000,
          writeBytesPerSecond: 3_000
        ),
        AppStorageUsage(
          name: "Editor",
          bundlePath: "/Applications/Editor.app",
          readBytesPerSecond: 500,
          writeBytesPerSecond: 400
        ),
      ]
    )
  }

  @Test
  func extractsOutermostApplicationBundle() {
    let path =
      "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
    #expect(
      ProcessIdentityResolver.outermostApplicationPath(in: path)
        == "/Applications/Browser.app"
    )
    #expect(
      ProcessIdentityResolver.outermostApplicationPath(in: "/usr/bin/swift") == nil
    )
  }

  @Test
  func parsesAndAggregatesFinalNetworkDelta() throws {
    let output = """
      ,bytes_in,bytes_out,
      Browser.10,9000,8000,
      ,bytes_in,bytes_out,
      Browser.10,500,20,
      Browser Helper.11,250,30,
      "Odd, Name.12",100,50,
      """
    let samples = try #require(NetTopOutputParser.parseFinalDeltaBlock(output))

    #expect(samples.count == 3)
    #expect(samples[2].name == "Odd, Name")
    #expect(samples[2].processIdentifier == 12)

    let usages = NetTopOutputParser.aggregate(
      samples,
      identitiesByProcessIdentifier: [
        10: NetworkAppIdentity(
          name: "Browser",
          bundlePath: "/Applications/Browser.app"
        ),
        11: NetworkAppIdentity(
          name: "Browser",
          bundlePath: "/Applications/Browser.app"
        ),
      ],
      limit: 5
    )

    #expect(
      usages == [
        AppNetworkUsage(
          name: "Browser",
          bundlePath: "/Applications/Browser.app",
          downloadBytesPerSecond: 750,
          uploadBytesPerSecond: 50
        ),
        AppNetworkUsage(
          name: "Odd, Name",
          bundlePath: nil,
          downloadBytesPerSecond: 100,
          uploadBytesPerSecond: 50
        ),
      ]
    )
  }
}
