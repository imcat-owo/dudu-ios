// Extracted from OpenMinis Views/Chat/PaginatedMarkdownView.swift (pure function, no UI).
import Foundation

///
/// Rules:
///   - Track whether we're inside a fenced code block; never cut
///     mid-fence.
///   - When we hit a blank line outside a fence AND the buffered
///     content is ≥ `targetSize` chars, flush the buffer as a segment.
///   - Empty / whitespace-only segments are dropped so a long run of
///     blank lines doesn't produce phantom rows.
///
/// Time complexity: O(n) over the input. No regex, single pass.
func splitMarkdownIntoSegments(_ markdown: String, targetSize: Int) -> [String] {
    guard markdown.count > targetSize else { return [markdown] }
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    var segments: [String] = []
    var current: [Substring] = []
    var currentLen = 0
    var inFence = false
    var fenceMarker = ""
    var sawBlankSinceContent = false

    func flush() {
        guard !current.isEmpty else { return }
        var joined = current.joined(separator: "\n")
        while joined.hasSuffix("\n") { joined.removeLast() }
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(joined)
        }
        current = []
        currentLen = 0
        sawBlankSinceContent = false
    }

    for line in lines {
        let lineStr = String(line)
        let stripped = lineStr.drop(while: { $0 == " " || $0 == "\t" })
        if !inFence, (stripped.hasPrefix("```") || stripped.hasPrefix("~~~")) {
            inFence = true
            fenceMarker = String(stripped.prefix(3))
        } else if inFence,
                  stripped.hasPrefix(fenceMarker),
                  stripped.drop(while: { String($0) == String(fenceMarker.first!) })
                      .allSatisfy({ $0 == " " || $0 == "\t" }) {
            inFence = false
        }
        current.append(line)
        currentLen += lineStr.count + 1
        let isBlank = lineStr.allSatisfy { $0 == " " || $0 == "\t" }
        if isBlank && !inFence && !sawBlankSinceContent && currentLen >= targetSize {
            flush()
            continue
        }
        if isBlank {
            sawBlankSinceContent = true
        } else {
            sawBlankSinceContent = false
        }
    }
    flush()
    return segments
}
