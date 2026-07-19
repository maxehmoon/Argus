import Darwin
import Foundation

public struct AppNetworkUsage: Sendable, Equatable {
  public let name: String
  public let bundlePath: String?
  public let downloadBytesPerSecond: Double
  public let uploadBytesPerSecond: Double

  public init(
    name: String,
    bundlePath: String?,
    downloadBytesPerSecond: Double,
    uploadBytesPerSecond: Double
  ) {
    self.name = name
    self.bundlePath = bundlePath
    self.downloadBytesPerSecond = downloadBytesPerSecond
    self.uploadBytesPerSecond = uploadBytesPerSecond
  }
}

public final class NetworkProcessSampler: Sendable {
  public init() {}

  public func topApplications(limit: Int = 5) async -> [AppNetworkUsage] {
    guard limit > 0, !Task.isCancelled else { return [] }

    let usages = await Task.detached(priority: .userInitiated) {
      Self.sampleTopApplications(limit: limit)
    }.value

    return Task.isCancelled ? [] : usages
  }

  private static func sampleTopApplications(limit: Int) -> [AppNetworkUsage] {
    let process = Process()
    let output = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    process.arguments = [
      "-P", "-d", "-x", "-L", "2", "-s", "1", "-t", "external",
      "-J", "bytes_in,bytes_out", "-n",
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return []
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      return []
    }

    let samples = NetTopOutputParser.parseFinalDeltaBlock(
      String(decoding: data, as: UTF8.self)
    )
    var identities: [pid_t: NetworkAppIdentity] = [:]
    identities.reserveCapacity(samples.count)
    for sample in samples {
      guard let processIdentifier = sample.processIdentifier,
        identities[processIdentifier] == nil,
        let identity = NetworkProcessIdentityResolver.identity(
          for: processIdentifier,
          fallbackName: sample.name
        )
      else {
        continue
      }
      identities[processIdentifier] = identity
    }

    return NetTopOutputParser.aggregate(
      samples,
      identitiesByProcessIdentifier: identities,
      limit: limit
    )
  }
}

struct NetTopProcessSample: Sendable, Equatable {
  let name: String
  let processIdentifier: pid_t?
  let bytesIn: Double
  let bytesOut: Double
}

struct NetworkAppIdentity: Sendable, Equatable {
  let name: String
  let bundlePath: String?
}

enum NetTopOutputParser {
  static func parseFinalDeltaBlock(_ output: String) -> [NetTopProcessSample] {
    var foundHeader = false
    var finalBlock: [NetTopProcessSample] = []

    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }

      if isHeader(line) {
        foundHeader = true
        finalBlock.removeAll(keepingCapacity: true)
      } else if foundHeader, let sample = parseDataRow(line) {
        finalBlock.append(sample)
      }
    }

    return finalBlock
  }

  static func aggregate(
    _ samples: [NetTopProcessSample],
    identitiesByProcessIdentifier: [pid_t: NetworkAppIdentity] = [:],
    limit: Int
  ) -> [AppNetworkUsage] {
    guard limit > 0 else { return [] }

    struct Totals {
      let name: String
      let bundlePath: String?
      var bytesIn: Double
      var bytesOut: Double
    }

    var totalsByApplication: [String: Totals] = [:]
    totalsByApplication.reserveCapacity(samples.count)

    for sample in samples where sample.bytesIn > 0 || sample.bytesOut > 0 {
      let identity =
        sample.processIdentifier.flatMap {
          identitiesByProcessIdentifier[$0]
        } ?? NetworkAppIdentity(name: sample.name, bundlePath: nil)
      let key = identity.bundlePath.map { "path:\($0)" } ?? "name:\(identity.name)"

      if var totals = totalsByApplication[key] {
        totals.bytesIn += sample.bytesIn
        totals.bytesOut += sample.bytesOut
        totalsByApplication[key] = totals
      } else {
        totalsByApplication[key] = Totals(
          name: identity.name,
          bundlePath: identity.bundlePath,
          bytesIn: sample.bytesIn,
          bytesOut: sample.bytesOut
        )
      }
    }

    return totalsByApplication.values
      .sorted { left, right in
        let leftTotal = left.bytesIn + left.bytesOut
        let rightTotal = right.bytesIn + right.bytesOut
        if leftTotal != rightTotal {
          return leftTotal > rightTotal
        }
        if left.bytesIn != right.bytesIn {
          return left.bytesIn > right.bytesIn
        }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
      }
      .prefix(limit)
      .map {
        AppNetworkUsage(
          name: $0.name,
          bundlePath: $0.bundlePath,
          downloadBytesPerSecond: $0.bytesIn,
          uploadBytesPerSecond: $0.bytesOut
        )
      }
  }

  private static func isHeader(_ line: String) -> Bool {
    guard let columns = columnsParsedFromRight(line) else { return false }
    return columns.name.isEmpty
      && unquoted(columns.second) == "bytes_in"
      && unquoted(columns.third) == "bytes_out"
  }

  private static func parseDataRow(_ line: String) -> NetTopProcessSample? {
    guard let columns = columnsParsedFromRight(line),
      let bytesIn = Double(unquoted(columns.second)),
      let bytesOut = Double(unquoted(columns.third)),
      bytesIn.isFinite,
      bytesOut.isFinite,
      bytesIn >= 0,
      bytesOut >= 0
    else {
      return nil
    }

    let processField = unquoted(columns.name)
    let process = splitProcessIdentifier(from: processField)
    guard !process.name.isEmpty else { return nil }

    return NetTopProcessSample(
      name: process.name,
      processIdentifier: process.identifier,
      bytesIn: bytesIn,
      bytesOut: bytesOut
    )
  }

  private static func columnsParsedFromRight(
    _ line: String
  ) -> (name: String, second: String, third: String)? {
    var content = line[...]
    if content.last == "," {
      content.removeLast()
    }

    guard let thirdSeparator = content.lastIndex(of: ",") else { return nil }
    let third = content[content.index(after: thirdSeparator)...]
    let beforeThird = content[..<thirdSeparator]
    guard let secondSeparator = beforeThird.lastIndex(of: ",") else { return nil }

    let name = beforeThird[..<secondSeparator]
    let second = beforeThird[beforeThird.index(after: secondSeparator)...]
    return (
      String(name).trimmingCharacters(in: .whitespaces),
      String(second).trimmingCharacters(in: .whitespaces),
      String(third).trimmingCharacters(in: .whitespaces)
    )
  }

  private static func splitProcessIdentifier(
    from processField: String
  ) -> (name: String, identifier: pid_t?) {
    guard let separator = processField.lastIndex(of: ".") else {
      return (processField, nil)
    }

    let identifierStart = processField.index(after: separator)
    let identifierText = processField[identifierStart...]
    guard !identifierText.isEmpty,
      identifierText.allSatisfy(\.isNumber),
      let identifier = pid_t(identifierText)
    else {
      return (processField, nil)
    }

    return (String(processField[..<separator]), identifier)
  }

  private static func unquoted(_ field: String) -> String {
    let trimmed = field.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else {
      return trimmed
    }

    return String(trimmed.dropFirst().dropLast())
      .replacingOccurrences(of: "\"\"", with: "\"")
  }
}

private enum NetworkProcessIdentityResolver {
  private static let pathBufferSize = 4 * 1_024

  static func identity(
    for processIdentifier: pid_t,
    fallbackName: String
  ) -> NetworkAppIdentity? {
    let path = withUnsafeTemporaryAllocation(
      of: CChar.self,
      capacity: pathBufferSize
    ) { buffer -> String? in
      guard let baseAddress = buffer.baseAddress else { return nil }
      let length = proc_pidpath(
        processIdentifier,
        baseAddress,
        UInt32(buffer.count)
      )
      guard length > 0 else { return nil }
      return String(cString: baseAddress)
    }

    guard let path, let bundlePath = outerApplicationPath(in: path) else {
      return nil
    }

    let applicationName = URL(fileURLWithPath: bundlePath)
      .deletingPathExtension()
      .lastPathComponent
    return NetworkAppIdentity(
      name: applicationName.isEmpty ? fallbackName : applicationName,
      bundlePath: bundlePath
    )
  }

  private static func outerApplicationPath(in executablePath: String) -> String? {
    if executablePath.hasSuffix(".app") {
      return executablePath
    }
    guard
      let range = executablePath.range(
        of: ".app/",
        options: [.caseInsensitive]
      )
    else {
      return nil
    }
    return String(executablePath[..<range.upperBound].dropLast())
  }
}
