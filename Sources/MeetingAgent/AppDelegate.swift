import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AgentModel()
    private let detector = CallDetector()
    private let recorder = CallRecorder()

    private var panel: FloatingPanel?
    private var hosting: NSHostingView<PanelView>?
    private var statusItem: NSStatusItem?
    private var autoRecordItem: NSMenuItem?
    private var cancellable: AnyCancellable?

    private var dismissedCall: DetectedCall?
    private var lastFolder: URL?

    private var autoRecord: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRecord") }
        set { UserDefaults.standard.set(newValue, forKey: "autoRecord") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPanel()
        wireModel()

        detector.onChange = { [weak self] state in
            self?.handle(state)
        }
        recorder.onUnexpectedStop = { [weak self] message in
            DispatchQueue.main.async { self?.recordingEndedUnexpectedly(message) }
        }
        detector.start()
        Log.write("Meeting Agent started. Auto-record is \(autoRecord ? "on" : "off").")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best effort: stop capture so the files are closed properly.
        // Detached so it doesn't need the main thread, which is waiting right here.
        let done = DispatchSemaphore(value: 0)
        let recorder = self.recorder
        Task.detached {
            await recorder.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    // MARK: - Setup

    private func setUpPanel() {
        let view = NSHostingView(rootView: PanelView(model: model))
        hosting = view
        let panel = FloatingPanel(content: view)
        self.panel = panel
        panel.fitToContent()
        panel.moveToTopRight()
        panel.orderFrontRegardless()

        // Re-fit after each state change, once SwiftUI has laid the new content out.
        cancellable = model.objectWillChange.sink { [weak panel] in
            DispatchQueue.main.async { panel?.fitToContent() }
        }
    }

    private func wireModel() {
        model.onRecord = { [weak self] in
            guard let self, case .callFound(let call) = self.model.state else { return }
            self.beginRecording(call)
        }
        model.onStop = { [weak self] in self?.endRecording() }
        model.onIgnore = { [weak self] in
            guard let self else { return }
            if case .callFound(let call) = self.model.state { self.dismissedCall = call }
            self.model.state = .idle
        }
        model.onRevealLast = { [weak self] in self?.revealLastRecording() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Meeting Agent")
        statusItem = item

        let menu = NSMenu()
        let auto = NSMenuItem(title: "Record detected calls automatically", action: #selector(toggleAutoRecord), keyEquivalent: "")
        auto.target = self
        auto.state = autoRecord ? .on : .off
        autoRecordItem = auto
        menu.addItem(auto)

        let show = NSMenuItem(title: "Show or hide window", action: #selector(togglePanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let windows = NSMenuItem(title: "Log visible windows (for tuning detection)", action: #selector(logWindows), keyEquivalent: "")
        windows.target = self
        menu.addItem(windows)

        let folder = NSMenuItem(title: "Open recordings folder", action: #selector(openRecordings), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Meeting Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    // MARK: - Detection and recording

    private func handle(_ state: CallState) {
        switch state {
        case .active(let call):
            guard !recorder.isRecording, call != dismissedCall else { return }
            if autoRecord {
                beginRecording(call)
            } else {
                model.state = .callFound(call)
            }
        case .idle:
            dismissedCall = nil
            if recorder.isRecording {
                endRecording()
            } else if case .callFound = model.state {
                model.state = .idle
            }
        }
    }

    private func beginRecording(_ call: DetectedCall) {
        Task { @MainActor in
            do {
                try await recorder.start(call: call)
                detector.isRecording = true
                model.state = .recording(call: call, since: Date())
                setStatusIcon(recording: true)
            } catch {
                Log.write("could not start recording: \(error.localizedDescription)")
                model.state = .error(error.localizedDescription)
            }
        }
    }

    private func endRecording() {
        Task { @MainActor in
            let folder = await recorder.stop()
            detector.isRecording = false
            setStatusIcon(recording: false)
            if let folder {
                lastFolder = folder
                model.lastSaved = folder.lastPathComponent
            }
            model.state = .idle
        }
    }

    private func recordingEndedUnexpectedly(_ message: String) {
        Task { @MainActor in
            await recorder.stop()
            detector.isRecording = false
            setStatusIcon(recording: false)
            model.state = .error("Recording stopped: \(message)")
        }
    }

    private func setStatusIcon(recording: Bool) {
        let name = recording ? "record.circle.fill" : "record.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Agent")
        statusItem?.button?.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Menu actions

    @objc private func toggleAutoRecord() {
        autoRecord.toggle()
        autoRecordItem?.state = autoRecord ? .on : .off
        Log.write("auto-record turned \(autoRecord ? "on" : "off")")
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func logWindows() {
        Log.write("visible windows (mic in use: \(CallDetector.microphoneInUse())):")
        for window in CallDetector.onScreenWindows() where window.layer == 0 {
            Log.write("  [\(window.owner)] \"\(window.title)\"")
        }
    }

    @objc private func openRecordings() {
        NSWorkspace.shared.open(Log.root)
    }

    private func revealLastRecording() {
        guard let lastFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFolder])
    }
}
