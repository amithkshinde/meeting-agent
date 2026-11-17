import Foundation

/// One piece of recognised speech with its position in the recording.
struct TimedToken: Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct Utterance: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// Turns the word pieces a speech engine returns into transcript lines. No speech engine is needed here,
/// so the logic can be tested on its own.
enum TranscriptBuilder {
    /// Groups word pieces into sentences. A new sentence starts after a pause, after . ? ! or when it gets long.
    /// Pieces that begin a word start with "▁" (a SentencePiece marker) or a space.
    static func utterances(from tokens: [TimedToken], pause: Double = 1.2, longest: Double = 20) -> [Utterance] {
        var result: [Utterance] = []
        var text = ""
        var start: Double?
        var end = 0.0

        func flush() {
            let cleaned = text.replacingOccurrences(of: "▁", with: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if let begin = start, !cleaned.isEmpty {
                result.append(Utterance(start: begin, end: max(end, begin), text: cleaned))
            }
            text = ""
            start = nil
        }

        for token in tokens {
            let startsWord = token.text.hasPrefix("▁") || token.text.hasPrefix(" ")
            if start != nil {
                let gap = token.start - end
                let length = token.end - (start ?? token.start)
                let previousEndsSentence = text.last.map { ".?!".contains($0) } ?? false
                if startsWord && (gap > pause || length > longest || previousEndsSentence) { flush() }
            }
            if start == nil { start = token.start }
            text += token.text
            end = token.end
        }
        flush()
        return result
    }

    /// "[mm:ss]" stamped at the END of the sentence, which is what the live transcriber does and what click-to-seek expects.
    static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "[%02d:%02d]", total / 60, total % 60)
    }

    /// Both sides of the call in time order: "[mm:ss] You: …" and "[mm:ss] Them: …".
    static func merge(you: [Utterance], them: [Utterance], youName: String = "You", themName: String = "Them") -> String {
        var rows: [(Double, String, Utterance)] = []
        rows += you.map { ($0.end, youName, $0) }
        rows += them.map { ($0.end, themName, $0) }
        // Stable order: by end time, then "You" first so equal stamps do not jump around.
        rows.sort { $0.0 == $1.0 ? ($0.1 == youName && $1.1 != youName) : $0.0 < $1.0 }
        return rows.map { "\(stamp($0.0)) \($0.1): \($0.2.text)" }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    /// Drops "You" lines that are just the call audio leaking into the microphone (no headphones).
    /// A mic sentence is an echo when a "Them" sentence ends within 3 seconds and says nearly the same words.
    static func removeEchoes(you: [Utterance], them: [Utterance]) -> [Utterance] {
        you.filter { mine in
            !them.contains { theirs in
                abs(theirs.end - mine.end) <= 3 && similarity(mine.text, theirs.text) >= 0.7
            }
        }
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Share of the shorter sentence's words that also appear in the other.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        let smaller = min(wa.count, wb.count)
        guard smaller >= 3 else { return 0 }
        return Double(wa.intersection(wb).count) / Double(smaller)
    }
}
