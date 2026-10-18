import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var agent: AgentModel
    @State private var keyDraft = ""
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @AppStorage("autoRecord") private var autoRecord = false
    @AppStorage("speechLocale") private var locale = "auto"
    @AppStorage("aiLocalOnly") private var aiLocal = false
    @AppStorage("calendarOn") private var calendarOn = true

    private struct Language: Identifiable {
        let id: String
        let name: String
    }

    private var languages: [Language] {
        [Language(id: "auto", name: "Automatic (English)")]
            + TrackTranscriber.supportedLanguages().map { Language(id: $0.id, name: $0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.largeTitle.bold())
                aiCard
                recordingCard
                calendarCard
                SetupChecklist(model: model, title: "Permissions")
                shortcutsCard
                generalCard
                dataCard
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: AI

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI assistant").font(.headline)
                Spacer()
                if model.hasKey { Chip(text: "Ready", icon: "checkmark.circle.fill", tint: .green) }
                else { Chip(text: "Not connected", icon: "exclamationmark.circle", tint: .orange) }
            }
            Text("The AI writes your call summaries, finds promises, gives live suggestions and answers your questions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Where should the AI run?", selection: $aiLocal) {
                Text("In the cloud (best quality, needs a free key)").tag(false)
                Text("On this Mac only (private, simpler answers)").tag(true)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: aiLocal) { model.refreshSetup() }

            if aiLocal {
                if AIAccess.localAvailable {
                    Text("Nothing you write or say leaves this Mac. Answers are shorter and less detailed than the cloud AI, and very long calls are trimmed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(AIAccess.localProblem).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if !model.hasKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open the page below and sign in with your Google account.")
                        Text("2. Click “Create API key”, then copy it.")
                        Text("3. Paste it here and press Save.")
                    }
                    .font(.callout)
                    Link("Open Google AI Studio to get a free key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.callout)
                }
                HStack {
                    SecureField(model.hasKey ? "Paste a new key to replace the current one" : "Paste your key here", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Privacy: only the text of transcripts, notes and files is sent. Audio and video never leave your Mac. Free Google keys may let Google use what you send to improve its products. For confidential projects, switch that project to “this Mac only” from its ⋯ menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.keyTest.isEmpty {
                Text(model.keyTest).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Test connection") { model.testKey() }.buttonStyle(SoftButtonStyle()).disabled(model.keyTesting || !model.hasKey)
                if !aiLocal, model.hasKey {
                    Button("Remove key") { model.removeKey() }.buttonStyle(SoftButtonStyle())
                }
            }
        }
        .card()
    }

    // MARK: Calendar

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calendar").font(.headline)
                Spacer()
                if agent.calendarConnected { Chip(text: "Connected", icon: "checkmark.circle.fill", tint: .green) }
            }
            Text("Get a briefing a few minutes before each meeting, and have the people on the invite named in your notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agent.calendarConnected {
                Toggle("Brief me before meetings", isOn: $calendarOn)
            } else {
                Button("Connect Calendar") { agent.onConnectCalendar() }.buttonStyle(PrimaryButtonStyle())
                Text("To include Google Calendar: System Settings › Internet Accounts › Add Account › Google, and switch Calendars on. Then connect here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    // MARK: Shortcuts

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard shortcuts").font(.headline)
            Text("These work from any app, even while the call is in front.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(0..<shortcuts.count, id: \.self) { index in
                let item = shortcuts[index]
                HStack {
                    Text(item.keys)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    Text(item.what).font(.callout)
                    Spacer()
                }
            }
        }
        .card()
    }

    private let shortcuts: [(keys: String, what: String)] = [
        ("⌃⌥ M", "Show or hide the floating window"),
        ("⌃⌥ A", "Ask a question (cursor goes straight to the box)"),
        ("⌃⌥ S", "Peek at suggestions when quiet mode is on"),
        ("⌃⌥ R", "Start or stop recording"),
    ]

    private func saveKey() {
        model.saveKey(keyDraft)
        keyDraft = ""
    }

    // MARK: Recording

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording").font(.headline)

            Toggle(isOn: $autoRecord) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start recording automatically")
                    Text("Off means I ask you first whenever a call starts.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: Binding(
                get: { agent.copilotOn },
                set: { value in
                    agent.copilotOn = value
                    UserDefaults.standard.set(value, forKey: "copilotOn")
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live suggestions during calls")
                    Text("A running recap, plus questions to ask and points to push back on.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: Binding(
                get: { agent.quiet },
                set: { value in
                    agent.quiet = value
                    UserDefaults.standard.set(value, forKey: "quietMode")
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quiet mode")
                    Text("Hide suggestions on the floating window until you peek (⌃⌥ S). Good for sensitive calls.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Spoken language", selection: $locale) {
                ForEach(languages) { language in
                    Text(language.name).tag(language.id)
                }
            }
            .frame(maxWidth: 360)
            Text("Applies from your next recording. Pick Hindi or Kannada if most of the call is in it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: General

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General").font(.headline)
            Toggle("Open Meeting Agent when I log in", isOn: Binding(
                get: { loginOn },
                set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        Log.write("could not change open at login: \(error.localizedDescription)")
                    }
                    loginOn = SMAppService.mainApp.status == .enabled
                }
            ))
            HStack {
                Button("Show or hide the floating window") { agent.onTogglePanel() }.buttonStyle(SoftButtonStyle())
            }
            Text("The floating window is the small panel at the top right. It stays out of screen shares.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: Data

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your data").font(.headline)
            Text("Everything is stored on this Mac, in Movies › MeetingAgent: each call's video, audio, transcript and summary, plus your projects, notes and files. Your AI key is kept in the macOS Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open recordings folder") { NSWorkspace.shared.open(Log.root) }.buttonStyle(SoftButtonStyle())
                Button("Open activity log") {
                    NSWorkspace.shared.open(Log.root.appendingPathComponent("spike-log.txt"))
                }
                .buttonStyle(SoftButtonStyle())
            }
            Text("Tell the other people on a call that you are recording. Laws on recording differ by place.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}
