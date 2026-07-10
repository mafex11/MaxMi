import Foundation

/// Pure function to dedupe overlapping text across consecutive transcription windows
public enum RollingStitch {
    /// Stitch consecutive windows by detecting and removing overlap.
    /// Strategy: find the longest suffix of window[i] that matches a prefix of window[i+1],
    /// then drop that prefix from window[i+1] before appending.
    public static func stitch(_ windows: [String]) -> String {
        guard !windows.isEmpty else { return "" }

        var result = windows[0]

        for i in 1..<windows.count {
            let prev = result
            let next = windows[i]

            guard !next.isEmpty else { continue }

            // Find longest overlap: try decreasing suffix lengths of prev against prefix of next
            var overlapLength = 0
            let maxOverlap = min(prev.count, next.count)

            for len in (1...maxOverlap).reversed() {
                let suffixStart = prev.index(prev.endIndex, offsetBy: -len)
                let suffix = prev[suffixStart...]
                let prefixEnd = next.index(next.startIndex, offsetBy: len)
                let prefix = next[..<prefixEnd]

                if suffix == prefix {
                    overlapLength = len
                    break
                }
            }

            // Append the non-overlapping part of next
            if overlapLength > 0 {
                let nextStart = next.index(next.startIndex, offsetBy: overlapLength)
                let addition = next[nextStart...]
                if !addition.isEmpty {
                    result += addition
                }
            } else {
                // No overlap found, join with space
                if !result.isEmpty && !result.hasSuffix(" ") && !next.hasPrefix(" ") {
                    result += " "
                }
                result += next
            }
        }

        return result
    }
}
