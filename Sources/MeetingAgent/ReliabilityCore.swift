import Foundation

// MARK: - Why a recording ended

enum EndReason: String, Codable {
    case manualStop         // the person pressed Stop
    case callEnded          // the call really ended and nobody said otherwise
    case streamError        // macOS stopped the capture
    case stalled            // no sound or picture arrived for a while
    case sleep              // the Mac went to sleep
    case diskFull           // not enough free space
    case quit               // the app was quit
    case crashed            // found unfinished after a crash or force quit
    case startFailed        // never began
    case unknown

    /// True when the person asked for it or the call really ended. Everything else is a failure worth knowing about.
    var isNormal: Bool { self == .manualStop || self == .callEnded || self == .quit }

    var plain: String {
        switch self {
        case .manualStop: return "stopped by you"
        case .callEnded: return "the call ended"
        case .streamError: return "macOS stopped the capture"
        case .stalled: return "capture went silent"
        case .sleep: return "the Mac went to sleep"
        case .diskFull: return "the disk was almost full"
        case .quit: return "the app was quit"
        case .crashed: return "the app closed unexpectedly"
        case .startFailed: return "it could not start"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Ledger: one line per recording, so failures can be counted

struct LedgerEntry: Codable, Identifiable, Equatable {
    var id: String                 // the recording folder name
    var app: String
    var startedAt: Date
    var endedAt: Date?
    var automatic: Bool
    var reason: EndReason?
    var detail: String = ""
    var resumedFrom: String?       // set on the part that continues an interrupted recording
    var freeGBAtStart: Double?

    var seconds: Double { (endedAt ?? startedAt).timeIntervalSince(startedAt) }
}

final class RecordingLedger {
    let url: URL
    private(set) var entries: [LedgerEntry]
    private let queue = DispatchQueue(label: "meetingagent.ledger")
    static let maxEntries = 400

    init(url: URL) {
        self.url = url
        self.entries = Self.read(url)
    }

    private static func read(_ url: URL) -> [LedgerEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LedgerEntry].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        if let data = try? encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    func begin(_ entry: LedgerEntry) {
        queue.sync {
            entries.removeAll { $0.id == entry.id }
            entries.append(entry)
            persist()
        }
    }

    func finish(id: String, reason: EndReason, detail: String = "", at date: Date = Date()) {
        queue.sync {
            guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].endedAt == nil else { return }
            entries[index].endedAt = date
            entries[index].reason = reason
            entries[index].detail = detail
            persist()
        }
    }

    /// Anything still open when the app starts was cut off by a crash or a force quit.
    @discardableResult
    func closeOpenAsCrashed(at date: Date = Date()) -> [LedgerEntry] {
        queue.sync {
            var closed: [LedgerEntry] = []
            for index in entries.indices where entries[index].endedAt == nil {
                entries[index].endedAt = date
                entries[index].reason = .crashed
                entries[index].detail = "Found unfinished at the next launch."
                closed.append(entries[index])
            }
            if !closed.isEmpty { persist() }
            return closed
        }
    }

    /// Recordings that ended for a reason other than the person or the call, in the last `days` days.
    func failures(inLastDays days: Int, now: Date = Date()) -> [LedgerEntry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { ($0.endedAt ?? $0.startedAt) >= cutoff && ($0.reason.map { !$0.isNormal } ?? false) && $0.reason != .startFailed }
    }

    func count(inLastDays days: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.startedAt >= cutoff }.count
    }

    /// A short, plain table for reports and the Health card.
    func report(limit: Int = 25, now: Date = Date()) -> String {
        let recent = entries.suffix(limit)
        guard !recent.isEmpty else { return "No recordings yet." }
        let stamp = DateFormatter()
        stamp.dateFormat = "d MMM HH:mm"
        var lines = ["Recent recordings (newest last):"]
        for entry in recent {
            let minutes = Int((entry.seconds / 60).rounded())
            let how = entry.reason?.plain ?? "still open"
            var line = "• \(stamp.string(from: entry.startedAt)) · \(entry.app) · \(minutes) min · \(entry.automatic ? "auto" : "manual") · ended: \(how)"
            if !entry.detail.isEmpty { line += " (\(entry.detail))" }
            if entry.resumedFrom != nil { line += " · continued from an interrupted recording" }
            lines.append(line)
        }
        let bad = failures(inLastDays: 30, now: now).count
        lines.append("")
        lines.append("Last 30 days: \(count(inLastDays: 30, now: now)) recordings, \(bad) ended unexpectedly.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - "The call looks over": ask, never stop on its own

/// The detector can lose sight of a call when the tab loses focus, the title changes or the mic is
/// released for a moment. The app never ends a recording because of that. It waits, stays quiet while
/// sound is still arriving, and then asks the person whether to end it. Only they decide.
struct WrapUp {
    enum Decision: Equatable {
        case carryOn                       // nothing to show
        case ask                           // show "The call looks over. End recording or Keep recording?"
    }

    var grace: TimeInterval = 20           // how long the call must be gone before asking
    var soundIsRecent: TimeInterval = 20   // sound this recently means someone is still talking
    var longestExtension: TimeInterval = 300 // never hold the question back longer than this because of sound alone
    var snooze: TimeInterval = 900         // after "Keep recording", do not ask again for this long

    private(set) var idleSince: Date?
    private(set) var snoozedUntil: Date?

    var isWrappingUp: Bool { idleSince != nil }

    mutating func reset() { idleSince = nil; snoozedUntil = nil }

    /// The person said "Keep recording".
    mutating func keepRecording(now: Date) { snoozedUntil = now.addingTimeInterval(snooze) }

    mutating func update(now: Date, callIsLive: Bool, lastSound: Date?) -> Decision {
        if callIsLive {
            idleSince = nil
            snoozedUntil = nil
            return .carryOn
        }
        let since = idleSince ?? now
        idleSince = since
        if let snoozedUntil, now < snoozedUntil { return .carryOn }

        let waited = now.timeIntervalSince(since)
        let soundRecent = lastSound.map { now.timeIntervalSince($0) < soundIsRecent } ?? false
        if soundRecent && waited < longestExtension { return .carryOn }
        return waited >= grace ? .ask : .carryOn
    }
}

// MARK: - Is the capture still alive?

/// Counts what has arrived from the capture. Written from capture queues, read from the main thread.
final class ActivityTracker {
    enum Source: String { case system, mic, screen }

    private let lock = NSLock()
    private var lastBuffer: [Source: Date] = [:]
    private var counts: [Source: Int] = [:]
    private var lastLoud: Date?
    private var lastSystemSound: Date?
    private var micBuffers = 0
    private var micLoudBuffers = 0
    private(set) var startedAt = Date()

    /// RMS above this counts as sound. About -50 dB, so room noise alone does not keep a recording alive.
    static let loudThreshold: Float = 0.003

    func reset(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastBuffer = [:]; counts = [:]; lastLoud = nil; startedAt = now
        lastSystemSound = nil; micBuffers = 0; micLoudBuffers = 0
    }

    func note(_ source: Source, rms: Float? = nil, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastBuffer[source] = now
        counts[source, default: 0] += 1
        if let rms, rms > Self.loudThreshold { lastLoud = now }
        if let rms {
            if source == .system, rms > Self.systemSoundThreshold {
                lastSystemSound = now
                micBuffers = 0; micLoudBuffers = 0
            } else if source == .mic {
                micBuffers += 1
                if rms > Self.micSpeechThreshold { micLoudBuffers += 1 }
            }
        }
    }

    /// Anything above digital silence. A working call-audio track is never exactly zero while someone talks.
    static let systemSoundThreshold: Float = 0.0003
    /// Loud enough to be someone talking near the microphone.
    static let micSpeechThreshold: Float = 0.02

    /// True when the call audio has been blank for a long time while the microphone kept hearing talking.
    /// That means the other people can no longer be recorded (for example the sound output changed), so
    /// only the microphone is picking them up.
    func systemSilentWhileMicTalks(now: Date = Date(), after seconds: TimeInterval = 90) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let since = lastSystemSound ?? startedAt
        guard now.timeIntervalSince(startedAt) > seconds, now.timeIntervalSince(since) > seconds else { return false }
        guard lastBuffer[.system] != nil, micBuffers > 200 else { return false }
        return Double(micLoudBuffers) / Double(micBuffers) > 0.3
    }

    var lastSound: Date? { lock.lock(); defer { lock.unlock() }; return lastLoud }

    func count(_ source: Source) -> Int { lock.lock(); defer { lock.unlock() }; return counts[source, default: 0] }

    /// Returns a description if audio has stopped arriving altogether, otherwise nil.
    /// Audio buffers arrive continuously (silence included) while capture is healthy, so a gap means it is stuck.
    func stall(now: Date = Date(), after seconds: TimeInterval = 30) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(startedAt) > seconds else { return nil }
        let newest = [lastBuffer[.system], lastBuffer[.mic]].compactMap { $0 }.max()
        // If audio never arrived at all, restarting will not help (usually a permission), so that is not a stall.
        guard let newest else { return nil }
        let gap = now.timeIntervalSince(newest)
        return gap > seconds ? "no audio for \(Int(gap)) seconds" : nil
    }

    /// True when nothing at all has arrived for a long time after the recording began.
    func neverReceivedAudio(now: Date = Date(), after seconds: TimeInterval = 60) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now.timeIntervalSince(startedAt) > seconds && lastBuffer[.system] == nil && lastBuffer[.mic] == nil
    }

    func summary(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        func age(_ source: Source) -> String {
            guard let date = lastBuffer[source] else { return "never" }
            return "\(Int(now.timeIntervalSince(date)))s ago"
        }
        return "system audio \(counts[.system, default: 0]) (last \(age(.system))), mic \(counts[.mic, default: 0]) (last \(age(.mic))), frames \(counts[.screen, default: 0])"
    }
}

// MARK: - Disk space

enum DiskGuard {
    enum Verdict: Equatable { case fine, low(Int64), critical(Int64) }

    static let lowBytes: Int64 = 3 * 1_073_741_824
    static let criticalBytes: Int64 = 1_073_741_824

    static func verdict(freeBytes: Int64?) -> Verdict {
        guard let freeBytes else { return .fine }
        if freeBytes < criticalBytes { return .critical(freeBytes) }
        if freeBytes < lowBytes { return .low(freeBytes) }
        return .fine
    }
}

// MARK: - Retry after an interruption

struct ResumePolicy {
    var maxResumes = 3

    /// Whether to start a new recording after macOS stopped the capture.
    func shouldResume(reason: EndReason, resumesSoFar: Int, callStillLive: Bool, wasStoppedByUser: Bool) -> Bool {
        guard !wasStoppedByUser, callStillLive, resumesSoFar < maxResumes else { return false }
        return reason == .streamError || reason == .stalled
    }
}

/// The error's domain and number, so the log shows exactly what macOS reported.
enum CaptureErrorNames {
    static func describe(domain: String, code: Int, message: String) -> String {
        "\(message) [\(domain) \(code)]"
    }
}
