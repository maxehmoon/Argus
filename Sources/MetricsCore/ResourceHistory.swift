public struct HistoryValue: Sendable, Equatable {
  public let position: Double
  public let value: Double
}

// Retain missing samples in the timeline, so a failed read cannot be bridged by
// the next successful one. The renderer draws each segment independently.
public func historySegments(
  positions: [Double], values: [Double?], breaks: [Bool]
) -> [[HistoryValue]] {
  var segments: [[HistoryValue]] = []
  var segment: [HistoryValue] = []
  for index in positions.indices {
    let position = positions[index]
    let value = values.indices.contains(index) ? values[index] : nil
    let startsSegment = breaks.indices.contains(index) && breaks[index]
    if startsSegment || value?.isFinite != true || !position.isFinite || position < 0
      || position > 1
    {
      if !segment.isEmpty {
        segments.append(segment)
        segment = []
      }
    }
    guard let value, value.isFinite, position.isFinite, (0...1).contains(position) else { continue }
    segment.append(HistoryValue(position: position, value: max(0, value)))
  }
  if !segment.isEmpty { segments.append(segment) }
  return segments
}

public func historyHasGap(elapsed: Double, previousInterval: Double, currentInterval: Double)
  -> Bool
{
  elapsed > max(previousInterval, currentInterval) * 1.75
}
