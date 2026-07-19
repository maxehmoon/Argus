import Testing

@testable import MetricsCore

@Suite("Stats formatting")
struct StatsFormatterTests {
  @Test
  func formatsPercentages() {
    #expect(StatsFormatter.percentage(42.4) == "42%")
    #expect(StatsFormatter.percentage(42.5) == "43%")
  }

  @Test
  func formatsDetailedRates() {
    #expect(StatsFormatter.rate(512) == "512 B/s")
    #expect(StatsFormatter.rate(320 * 1_000) == "320 KB/s")
    #expect(StatsFormatter.rate(5.25 * 1_000_000) == "5.2 MB/s")
    #expect(StatsFormatter.rate(2.5 * 1_000_000_000) == "2.5 GB/s")
  }

  @Test
  func formatsApplicationMemory() {
    #expect(StatsFormatter.memory(512) == "512 B")
    #expect(StatsFormatter.memory(512 * 1_000) == "512 KB")
    #expect(StatsFormatter.memory(920 * 1_000_000) == "920 MB")
    #expect(StatsFormatter.memory(UInt64(2.25 * 1_000_000_000)) == "2.2 GB")
    #expect(StatsFormatter.gigabytes(1_000_000_000) == "1.0")
  }

  @Test
  func formatsCompactMemory() {
    #expect(StatsFormatter.compactMemory(0) == "0B")
    #expect(StatsFormatter.compactMemory(1_000_000) == "1M")
    #expect(StatsFormatter.compactMemory(1_500_000_000) == "1.5G")
  }

  @Test
  func formatsLoadAndDuration() {
    #expect(StatsFormatter.loadAverage(1.234) == "1.23")
    #expect(
      StatsFormatter.loadAverages(
        LoadAverages(oneMinute: 1.2, fiveMinutes: 2.34, fifteenMinutes: 3.456)
      ) == "1.2 · 2.3 · 3.5"
    )
    #expect(StatsFormatter.temperature(72.6) == "73°C")
    #expect(StatsFormatter.frequency(3_504) == "3.50 GHz")
    #expect(StatsFormatter.frequency(850) == "850 MHz")
    #expect(StatsFormatter.uptime(5 * 24 * 60 * 60 + 14 * 60 * 60) == "5d 14h")
    #expect(StatsFormatter.duration(minutes: 42) == "42m")
    #expect(StatsFormatter.duration(minutes: 120) == "2h")
    #expect(StatsFormatter.duration(minutes: 134) == "2h 14m")
  }

  @Test
  func formatsCountryFlags() {
    #expect(StatsFormatter.countryFlag(countryCode: "gr") == "🇬🇷")
    #expect(StatsFormatter.countryFlag(countryCode: "US") == "🇺🇸")
    #expect(StatsFormatter.countryFlag(countryCode: "GRC") == nil)
    #expect(StatsFormatter.countryFlag(countryCode: "1A") == nil)
  }

  @Test
  func calculatesMemoryPercentage() {
    let snapshot = StatsSnapshot(
      cpuPercent: 0,
      memoryUsed: 8,
      memoryTotal: 16,
      downloadBytesPerSecond: 0,
      uploadBytesPerSecond: 0
    )
    #expect(snapshot.memoryPercent == 50)
  }
}
