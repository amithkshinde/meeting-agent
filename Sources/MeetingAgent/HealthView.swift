import SwiftUI

/// Settings card: how the recorder has been doing, and a way to send the details when it fails.
struct HealthCard: View {
    @State private var note = ""
    @State private var status = ""
    @State private var busy = false
    @State private var shareName = false
    @AppStorage("feedbackName") private var savedName = ""
    @AppStorage("feedbackReplyEmail") private var savedEmail = ""
    @State private var refresh = 0

    private var recent: [LedgerEntry] { Array(Health.ledger.entries.suffix(5).reversed()) }
    private var failures: Int { Health.ledger.failures(inLastDays: 30).count }
    private var total: Int { Health.ledger.count(inLastDays: 30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recorder health").font(.title3.bold())

            UpdateRow()

            Text(total == 0
                 ? "No recordings yet."
                 : "Last 30 days: \(total) recording\(total == 1 ? "" : "s"), \(failures) ended unexpectedly.")
                .font(.callout)
                .foregroundStyle(failures > 0 ? Color.orange : Color.secondary)

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recent) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: (entry.reason?.isNormal ?? true) ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle((entry.reason?.isNormal ?? true) ? Color.green : Color.orange)
                                .font(.caption)
                            Text("\(entry.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.app) · \(Int((entry.seconds / 60).rounded())) min · \(entry.reason?.plain ?? "still recording")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .id(refresh)
            }

            Text("Meeting Agent keeps a private activity log on this Mac, with keys and email addresses removed. If a recording stopped when it shouldn't have, send a report and say what you were doing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("What happened? (optional)", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)

            if !savedEmail.isEmpty || !savedName.isEmpty {
                Toggle("Include my name and email from Feedback so you can reply to me", isOn: $shareName)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack {
                Button(busy ? "Sending…" : "Send report") { send() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
                Button("Open logs folder") { Health.openLogsFolder() }
                    .buttonStyle(SoftButtonStyle())
                Button("Refresh") { refresh += 1 }
                    .buttonStyle(SoftButtonStyle())
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private func send() {
        busy = true
        status = ""
        let text = note
        let useName = shareName
        Task { @MainActor in
            status = await Health.sendReport(note: text, name: useName ? savedName : "", email: useName ? savedEmail : "", anonymous: !useName)
            busy = false
        }
    }
}

/// One line in Settings: is the Parakeet model ready, and a button to fetch it now instead of after the first call.
struct ParakeetStatusRow: View {
    @ObservedObject private var engine = ParakeetEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(ParakeetEngine.describe(engine.state)).font(.callout)
                Spacer()
                if engine.state != .ready, !isDownloading {
                    Button(buttonTitle) { Task { await engine.prepare() } }
                        .buttonStyle(SoftButtonStyle())
                }
            }
            if case .downloading(let fraction) = engine.state {
                ProgressView(value: fraction)
            }
            if case .failed = engine.state {
                Text("If this keeps failing, check your internet connection once. After the first download the model works offline. Calls still get the live transcript meanwhile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var isDownloading: Bool {
        if case .downloading = engine.state { return true }
        return false
    }

    private var buttonTitle: String {
        if case .failed = engine.state { return "Try again" }
        return "Download now (about 480 MB)"
    }

    private var icon: String {
        switch engine.state {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "waveform"
        }
    }

    private var tint: Color {
        switch engine.state {
        case .ready: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

/// "Version 0.2.0 · Check for updates".
struct UpdateRow: View {
    @ObservedObject private var checker = UpdateChecker.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Version \(version)").font(.callout)
            Text(statusText).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if case .available = checker.state {
                Button("Download update") { checker.download() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Check for updates") { Task { await checker.check(manual: true) } }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(checker.state == .checking)
            }
        }
    }

    private var statusText: String {
        switch checker.state {
        case .idle: return ""
        case .checking: return "· checking…"
        case .upToDate: return "· up to date"
        case .available(let version): return "· \(version) is available"
        case .failed: return "· couldn't check (are you online?)"
        }
    }
}
