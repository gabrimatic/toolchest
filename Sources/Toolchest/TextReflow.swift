import Foundation

/// Deterministic tidy-up for text read off the screen: no model, so nothing in a screenshot can
/// steer it. It only removes line breaks and spaces; it never adds, changes or drops a word.
///
/// - Trailing spaces go, runs of spaces and tabs inside a line become one space.
/// - A word split across lines with a hyphen ("appoint-" / "ment") is joined when the next line
///   starts with a lowercase letter.
/// - A line that doesn't end a sentence is joined to the next when the next starts with a
///   lowercase letter or a digit (the usual soft wrap).
/// - Blank lines (paragraphs), list items, and lines after sentence-ending punctuation stay apart.
enum TextReflow {
    static func reflow(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map(normalize)
        var output: [String] = []
        for line in lines {
            guard let previous = output.last, !previous.isEmpty, !line.isEmpty, !isListItem(line),
                  let first = line.first, first.isLowercase || first.isNumber,
                  !endsSentence(previous) || previous.hasSuffix("-") else {
                output.append(line)
                continue
            }
            if previous.hasSuffix("-"), previous.count > 1, previous.dropLast().last?.isLetter == true, first.isLowercase {
                output[output.count - 1] = String(previous.dropLast()) + line
            } else if previous.hasSuffix("-") {
                output.append(line)
            } else {
                output[output.count - 1] = previous + " " + line
            }
        }
        // Collapse runs of blank lines to one.
        var collapsed: [String] = []
        for line in output where !(line.isEmpty && collapsed.last?.isEmpty == true) { collapsed.append(line) }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ line: String) -> String {
        line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return true }
        return ".!?:;。！？".contains(last)
    }

    static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") || line.hasPrefix("– ") { return true }
        let prefix = line.prefix { $0.isNumber }
        if !prefix.isEmpty, prefix.count <= 3 {
            let rest = line.dropFirst(prefix.count)
            return rest.hasPrefix(". ") || rest.hasPrefix(") ")
        }
        return false
    }
}
