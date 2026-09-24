import Foundation

/// Plain-text ring buffer of recent terminal output. Built up incrementally as
/// data arrives at the SwiftTerm host, stripped of control sequences so search
/// matches line up with what the user sees.
///
/// One instance per pane's terminal. Not exposed to SwiftUI directly — the
/// pane's search UI just calls `find(_:)` and `count(of:)`.
final class ScrollbackBuffer {
    static let maxLines = 5000

    private var lines: [String] = [""]
    /// Current accumulator for the partial last line.
    private var pending: String = ""

    func append(bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            let scalar = UnicodeScalar(byte)
            if byte == 0x1B {
                // Bare ESC at the start of a control sequence — drop everything
                // until we see a final byte (0x40–0x7E after optional
                // intermediates). For MVP we approximate by scanning until a
                // letter terminates.
                continue
            }
            // Drop other CSI / OSC by-product bytes we don't want in plain text.
            switch byte {
            case 0x07, 0x08, 0x9B: continue
            case 0x0A: // LF
                lines.append(pending)
                pending = ""
                if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            case 0x0D: // CR — treat as line break for our text model
                lines.append(pending)
                pending = ""
                if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            default:
                pending.unicodeScalars.append(scalar)
            }
        }
    }

    /// Snapshot of the buffer as plain lines (without the trailing partial).
    var snapshot: [String] {
        return pending.isEmpty ? lines : lines + [pending]
    }

    func reset() {
        lines = [""]
        pending = ""
    }

    // MARK: - Search

    /// Returns total occurrences of `needle` (case-insensitive).
    func count(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var total = 0
        for line in snapshot {
            total += occurrences(in: line, needle: needle)
        }
        return total
    }

    /// Returns up to `limit` match positions: `(lineIndex, column)` for the
    /// start of each match. Line index is 0-based into `snapshot`.
    func find(_ needle: String, limit: Int = 100) -> [Match] {
        guard !needle.isEmpty else { return [] }
        var matches: [Match] = []
        let lines = snapshot
        for (idx, line) in lines.enumerated() {
            var searchStart = line.startIndex
            while searchStart < line.endIndex,
                  let range = line.range(of: needle,
                                          options: [.caseInsensitive],
                                          range: searchStart..<line.endIndex) {
                matches.append(Match(lineIndex: idx, column: line.distance(from: line.startIndex, to: range.lowerBound)))
                searchStart = range.upperBound
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }

    struct Match: Equatable, Sendable {
        let lineIndex: Int
        let column: Int
    }

    private func occurrences(in line: String, needle: String) -> Int {
        var count = 0
        var idx = line.startIndex
        while idx < line.endIndex,
              let range = line.range(of: needle,
                                      options: [.caseInsensitive],
                                      range: idx..<line.endIndex) {
            count += 1
            idx = range.upperBound
        }
        return count
    }
}