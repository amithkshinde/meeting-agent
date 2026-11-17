import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The app's activity log. Lines go to the console and to ~/Movies/MeetingAgent/Logs/meeting-agent.log,
/// which rotates at about 1.5 MB and keeps the last four files. Keys, email addresses and the account
/// name are removed from every line before it is written.
enum Log {
    static let root: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let url = movies.appendingPathComponent("MeetingAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let folder: URL = {
        let url = root.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let file = RotatingFile(url: folder.appendingPathComponent("meeting-agent.log"))
    static let markerURL = folder.appendingPathComponent("running.marker")

    private static let queue = DispatchQueue(label: "meetingagent.log")
    static var minimumLevel: LogLevel = .info

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    // MARK: - Writing

    static func debug(_ category: String, _ message: String) { emit(.debug, category, message) }
    static func info(_ category: String, _ message: String) { emit(.info, category, message) }
    static func warn(_ category: String, _ message: String) { emit(.warn, category, message) }
    static func error(_ category: String, _ message: String) { emit(.error, category, message) }

    /// Older call sites. Same as info under the category "app".
    static func write(_ message: String) { emit(.info, "app", message) }

    private static func emit(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= minimumLevel else { return }
        let line = LogFormat.line(level: level, category: category, message: message)
        print(line, terminator: "")
        queue.async { file.append(line) }
    }

    /// Waits until everything queued has been written. Used before quitting and before a report.
    static func flush() { queue.sync {} }

    // MARK: - Session

    /// Call once at launch. Writes a header and notes whether the last run ended badly.
    @discardableResult
    static func startSession() -> SessionMarker.Previous? {
        let previous = SessionMarker.begin(at: markerURL, version: version)
        info("session", "──────── Meeting Agent \(version) started ────────")
        info("session", Diagnostics.machineLine())
        info("session", Diagnostics.diskLine(at: root))
        if let previous {
            let when = ISO8601DateFormatter().string(from: previous.startedAt)
            warn("session", "The previous run (started \(when), version \(previous.version.isEmpty ? "unknown" : previous.version)) did not quit cleanly. It crashed, was force-quit, or the Mac lost power.")
        }
        return previous
    }

    static func endSession() {
        info("session", "Quit normally.")
        flush()
        SessionMarker.end(at: markerURL)
    }

    /// The last part of the log, for a report.
    static func tail(maxChars: Int = 20_000) -> String {
        flush()
        return file.tail(maxChars: maxChars)
    }
}

/// Facts about this Mac that help when something goes wrong.
enum Diagnostics {
    static func chip() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let name = String(cString: buffer)
        #if arch(arm64)
        return name.isEmpty ? "Apple silicon" : name
        #else
        return name.isEmpty ? "Intel" : name
        #endif
    }

    static func machineLine() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return "macOS \(os) · \(chip()) · \(String(format: "%.0f", gb)) GB memory"
    }

    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func diskLine(at url: URL) -> String {
        guard let free = freeBytes(at: url) else { return "Free disk space: unknown" }
        return "Free disk space: " + gigabytes(free)
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
