import Foundation

/// Checks on what the AI wrote, so notes that are not in the call never reach the user.
enum SummaryGuard {
    private static let stop: Set<String> = [
        "about", "after", "again", "also", "other", "their", "there", "these", "those", "which", "would", "could",
        "should", "being", "where", "while", "under", "meeting", "discussed", "mentioned", "asked", "agreed",
        "call", "team", "item", "items", "next", "need", "needs", "will", "with", "have", "that", "this", "from",
    ]

    /// Word beginnings (first five letters) of everything that was said.
    static func stems(_ text: String) -> Set<String> {
        var out = Set<String>()
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count >= 4 {
            out.insert(String(word.prefix(5)))
        }
        return out
    }

    private static func contentStems(of line: String) -> [String] {
        line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 5 && !stop.contains(String($0)) }
            .map { String($0.prefix(5)) }
    }

    private static func isBullet(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ")
    }

    /// Cleans a summary: keeps each heading once, drops a bullet that repeats an earlier one,
    /// and drops a bullet whose content words are mostly not in the transcript.
    /// Returns the cleaned text and how many bullets were removed for not being in the call.
    static func clean(_ summary: String, transcript: String) -> (text: String, dropped: Int) {
        let said = stems(transcript)
        var seenHeadings = Set<String>()
        var seenBullets = Set<String>()
        var out: [String] = []
        var skippingSection = false
        var dropped = 0
        for line in summary.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let key = t.lowercased()
                if t.hasPrefix("## ") || t.hasPrefix("# ") {
                    if seenHeadings.contains(key) { skippingSection = true; continue }
                    seenHeadings.insert(key)
                    skippingSection = false
                } else if skippingSection { continue }
                out.append(line)
                continue
            }
            if skippingSection { continue }
            if isBullet(line) {
                let norm = t.lowercased().filter { $0.isLetter || $0.isNumber }
                if seenBullets.contains(norm) { dropped += 1; continue }
                seenBullets.insert(norm)
                let words = contentStems(of: t)
                if words.count >= 4 {
                    let hit = words.filter { said.contains($0) }.count
                    if Double(hit) / Double(words.count) < 0.3 { dropped += 1; continue }
                }
            }
            out.append(line)
        }
        var text = out.joined(separator: "\n")
        // A heading left with nothing under it reads "None.".
        let lines = text.components(separatedBy: "\n")
        var fixed: [String] = []
        for (i, line) in lines.enumerated() {
            fixed.append(line)
            if line.hasPrefix("## ") {
                let rest = lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if rest == nil || rest!.hasPrefix("#") { fixed.append(""); fixed.append("None.") }
            }
        }
        text = fixed.joined(separator: "\n")
        return (text, dropped)
    }
}
