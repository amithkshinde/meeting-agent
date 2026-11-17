import AppKit
import AVFoundation
import ServiceManagement

/// Everything about how the app has been behaving: the recording ledger, a plain-text report that can be
/// sent when something goes wrong, and the places to find the log.
enum Health {
    static let ledger = RecordingLedger(url: Log.folder.appendingPathComponent("recordings-ledger.json"))

    // MARK: - Report

    /// Plain text a person can read before sending. Keys, emails and the account name are already removed from the log lines.
    static func reportText(note: String = "") -> String {
        var lines: [String] = []
        lines.append("Meeting Agent report · \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Version: \(Log.version)")
        lines.append(Diagnostics.machineLine())
        lines.append(Diagnostics.diskLine(at: Log.root))
        lines.append("Screen Recording permission: \(CGPreflightScreenCaptureAccess() ? "on" : "OFF")")
        lines.append("Microphone permission: \(micStatus())")
        lines.append("Auto-record: \(UserDefaults.standard.bool(forKey: "autoRecord") ? "on" : "off") · Start at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        lines.append("Transcription: \(TranscriptionStatus.summary)")
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("What happened (from the person):")
            lines.append(Redactor.clean(note))
        }
        lines.append("")
        lines.append(ledger.report())
        lines.append("")
        lines.append("───── Activity log (newest at the bottom) ─────")
        lines.append(Log.tail(maxChars: 30_000))
        return lines.joined(separator: "\n")
    }

    private static func micStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "on"
        case .denied: return "OFF"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    /// Saves the report on the Desktop, which is the easiest place for a person to find and attach it.
    @discardableResult
    static func saveReport(note: String = "") -> URL? {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let url = desktop.appendingPathComponent("MeetingAgent-report-\(formatter.string(from: Date())).txt")
        do {
            try reportText(note: note).write(to: url, atomically: true, encoding: .utf8)
            Log.info("report", "Saved a report to the Desktop")
            return url
        } catch {
            Log.error("report", "Could not save a report: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sends the report the best way available: posted online when an address is set, otherwise saved to the
    /// Desktop with an email draft opened. Returns a sentence to show the person.
    @MainActor
    static func sendReport(note: String, name: String, email: String, anonymous: Bool) async -> String {
        let text = reportText(note: note)
        let title = "Meeting Agent problem report"

        if let endpoint = FeedbackConfig.endpoint {
            var payload: [String: Any] = [
                "kind": "report",
                "anonymous": anonymous,
                "message": note.isEmpty ? "Automatic report" : note,
                "details": text,
                "text": text,
                "subject": title,
                "app": "Meeting Agent",
                "version": Log.version,
                "date": ISO8601DateFormatter().string(from: Date())
            ]
            if !anonymous { payload["name"] = name; payload["email"] = email }
            if let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                var request = URLRequest(url: endpoint, timeoutInterval: 20)
                request.httpMethod = "POST"
                request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    Log.info("report", "Report sent online")
                    return "Report sent. Thank you."
                }
                Log.warn("report", "Could not send the report online; falling back to a file")
            }
        }

        guard let file = saveReport(note: note) else { return "Could not save the report. Use “Open logs folder” and send the newest file." }
        NSWorkspace.shared.activateFileViewerSelecting([file])
        if FeedbackConfig.email.isEmpty == false {
            var parts = URLComponents()
            parts.scheme = "mailto"
            parts.path = FeedbackConfig.email
            parts.queryItems = [
                URLQueryItem(name: "subject", value: title + " · " + Log.version),
                URLQueryItem(name: "body", value: "Hi,\n\nThe recorder had a problem. I have attached the report file from my Desktop (\(file.lastPathComponent)).\n\n\(note)\n")
            ]
            if let raw = parts.percentEncodedQuery {
                parts.percentEncodedQuery = raw.replacingOccurrences(of: "+", with: "%2B")
            }
            if let url = parts.url { NSWorkspace.shared.open(url) }
            return "The report is saved on your Desktop (\(file.lastPathComponent)) and an email is open. Drag the file into it and send."
        }
        return "The report is saved on your Desktop (\(file.lastPathComponent)). Send it to whoever looks after Meeting Agent."
    }

    static func openLogsFolder() {
        NSWorkspace.shared.open(Log.folder)
    }
}
