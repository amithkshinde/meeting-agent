import Foundation

enum LogLevel: Int, Comparable {
    case debug = 0, info, warn, error

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }
}

/// Removes things that should never leave this Mac in a log: API keys, email addresses and the
/// account name in file paths. Applied to every line before it is written.
enum Redactor {
    static func clean(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            (#"AIza[0-9A-Za-z_\-]{20,}"#, "[key]"),
            (#"sk-[A-Za-z0-9_\-]{16,}"#, "[key]"),
            (#"(?i)(bearer|token|api[_-]?key|key)([=:]\s*|\s+)[A-Za-z0-9_\-\.]{20,}"#, "$1$2[key]"),
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
            (#"/Users/[^/\s]+"#, "/Users/~"),
            (#"C:\\Users\\[^\\\s]+"#, "C:\\Users\\~")
        ]
        for (pattern, replacement) in rules {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }
}

/// A log file that never grows without limit: when it passes `maxBytes` it is renamed to .1, .2 …
/// and the oldest is dropped, so at most `keep + 1` files exist.
final class RotatingFile {
    let url: URL
    private let maxBytes: Int
    private let keep: Int
    private let fm = FileManager.default

    init(url: URL, maxBytes: Int = 1_500_000, keep: Int = 3) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func rotated(_ index: Int) -> URL {
        URL(fileURLWithPath: url.path + ".\(index)")
    }

    /// Every file that belongs to this log, newest first.
    var allFiles: [URL] {
        ([url] + (1...max(keep, 1)).map { rotated($0) }).filter { fm.fileExists(atPath: $0.path) }
    }

    func append(_ line: String) {
        rotateIfNeeded(adding: line.utf8.count)
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded(adding: Int) {
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size + adding > maxBytes else { return }
        try? fm.removeItem(at: rotated(keep))
        if keep > 1 {
            for index in stride(from: keep - 1, through: 1, by: -1) {
                try? fm.moveItem(at: rotated(index), to: rotated(index + 1))
            }
        }
        try? fm.moveItem(at: url, to: rotated(1))
    }

    /// The last `maxChars` characters across the files, oldest first. Used for reports.
    func tail(maxChars: Int) -> String {
        var pieces: [String] = []
        var total = 0
        for file in allFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            pieces.insert(text, at: 0)
            total += text.count
            if total >= maxChars { break }
        }
        let joined = pieces.joined()
        guard joined.count > maxChars else { return joined }
        let cut = String(joined.suffix(maxChars))
        // Start on a whole line.
        if let newline = cut.firstIndex(of: "\n") { return String(cut[cut.index(after: newline)...]) }
        return cut
    }
}

enum LogFormat {
    static func line(level: LogLevel, category: String, message: String, date: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        let text = Redactor.clean(message).replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(stamp)  \(level.tag)  [\(category)]  \(text)\n"
    }
}

/// Tells the next launch whether the last run ended cleanly. A marker file is written at launch and
/// removed on a normal quit; if it is still there next time, the app was killed or crashed.
enum SessionMarker {
    struct Previous: Equatable {
        var startedAt: Date
        var version: String
    }

    /// Returns the previous run's details if it did not end cleanly, then marks this run as started.
    static func begin(at url: URL, version: String, now: Date = Date()) -> Previous? {
        var previous: Previous?
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
            if let first = parts.first, let seconds = Double(first) {
                previous = Previous(startedAt: Date(timeIntervalSince1970: seconds), version: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
            }
        }
        try? "\(now.timeIntervalSince1970)|\(version)".write(to: url, atomically: true, encoding: .utf8)
        return previous
    }

    static func end(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
