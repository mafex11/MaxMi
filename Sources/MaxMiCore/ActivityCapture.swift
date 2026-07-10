/// Pure activity-gate function for testing the focus-generation discard-on-mismatch rule.
/// Returns true if activity evidence should be recorded for this capture.
public func shouldRecordActivity(captureGeneration: Int, currentGeneration: Int, eligible: Bool) -> Bool {
    return captureGeneration == currentGeneration && eligible
}
