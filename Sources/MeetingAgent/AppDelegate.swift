import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = AgentModel()
    private let detector = CallDetector()
    private let recorder = CallRecorder()
    private let transcriber = LiveTranscriber()

    private var panel: FloatingPanel?
    private var hosting: NSHostingView<PanelView>?
    private var statusItem: NSStatusItem?
    private var recordItem: NSMenuItem?
    private var cancellable: AnyCancellable?

    private var chatHistory: [(question: String, answer: String)] = []
    private let memory = MemoryStore()
    private let knowledge = KnowledgeStore()
    private let projects = ProjectStore()
    private let commitments = CommitmentStore()
    private lazy var retriever = Retriever(memory: memory, knowledge: knowledge, projects: projects)
    private lazy var library = LibraryModel(memory: memory, knowledge: knowledge, projects: projects, retriever: retriever, agent: model, commitments: commitments)
    private lazy var processor = CallProcessor(memory: memory, knowledge: knowledge, projects: projects, commitments: commitments, agent: model)
    private lazy var calendar = CalendarService(agent: model, memory: memory, projects: projects, knowledge: knowledge, commitments: commitments, retriever: retriever)
    private var mainWindow: NSWindow?

    private var currentApp = ""
    private var currentTitle: String?
    private var currentAttendees: [Attendee] = []
    private var currentCallId: String?
    private var copilotTimer: Timer?
    private var watchdogTimer: Timer?
    private var perfTicks = 0
    private var systemFixTries = 0
    private var lastSystemFix = Date.distantPast
    private var lastLocalTick = Date.distantPast
    private var copilotBusy = false
    private var copilotFailures = 0
    private var geminiPauseShown = false
    private var lastGeminiTick = Date.distantPast
    private var lineCounter = 0
    private var lastCopilotLine = 0
    private var recordingStart = Date()
    private var speechOn = true
    private var dismissedCall: DetectedCall?
    private var lastFolder: URL?
    private var manualRecording = false
    private var wrapUp = WrapUp()
    private var wrapUpTimer: Timer?
    private var wrapUpWarnings = 0
    private var lastAskedAt: Date?
    private var currentLedgerId: String?
    private var currentCall: DetectedCall?
    private var resumeCount = 0
    private var lastSleepStop: (call: DetectedCall, at: Date, id: String)?
    private var lowDiskShown = false

    private var autoRecord: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRecord") }
        set { UserDefaults.standard.set(newValue, forKey: "autoRecord") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if offerMoveToApplications() { return }
        let uncleanExit = Log.startSession()
        if ScreenAccessHealer.healIfNeeded() { _ = CGRequestScreenCaptureAccess() }
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            NSApp.applicationIconImage = AppIcon.make()
        }
        setUpMainMenu()
        setUpStatusItem()
        setUpPanel()
        wireModel()
        processor.library = library
        library.processor = processor
        UNUserNotificationCenter.current().delegate = self

        transcriber.onLine = { [weak self] line in
            guard let self else { return }
            self.model.lines.append(line)
            self.lineCounter += 1
            if self.model.lines.count > 300 { self.model.lines.removeFirst(self.model.lines.count - 300) }
        }
        transcriber.onPartial = { [weak self] speaker, text in
            self?.model.partial[speaker] = text
        }
        recorder.transcriber = transcriber
        recorder.watcher.onSpeaker = { [weak self] name in self?.model.speakingNow = name }
        model.onBookmark = { [weak self] in self?.addBookmark() }

        detector.onChange = { [weak self] state in
            self?.handle(state)
        }
        recorder.onUnexpectedStop = { [weak self] message in
            DispatchQueue.main.async { self?.recordingEndedUnexpectedly(message) }
        }
        detector.start()
        calendar.start()
        registerHotKeys()
        observeSleep()
        recoverInterrupted()
        let cutOff = Health.ledger.closeOpenAsCrashed()
        Log.info("app", "Meeting Agent started. Auto-record is \(autoRecord ? "on" : "off").")
        if uncleanExit != nil || !cutOff.isEmpty {
            for entry in cutOff {
                Log.error("recorder", "Recording \(entry.id) was cut off by a crash or force quit after about \(Int(entry.seconds / 60)) min")
            }
            model.raise(AppAlert(
                id: "crashed",
                message: cutOff.isEmpty
                    ? "Meeting Agent closed unexpectedly last time. It has been noted in the log. If it keeps happening, send a report."
                    : "Meeting Agent closed unexpectedly during your last call. I kept what was recorded and I'm writing the notes. It has been logged. Please send a report so it can be fixed.",
                button: "Send report",
                section: LibraryModel.settingsKey
            ))
        }
        Task { await ParakeetEngine.shared.prepare() }
        UpdateChecker.shared.onAlert = { [weak self] alert in self?.model.raise(alert) }
        UpdateChecker.shared.isRecording = { [weak self] in
            guard let model = self?.model else { return false }
            if case .recording = model.state { return true }
            return false
        }
        UpdateChecker.shared.start()

        // Show the main window on a normal launch. When macOS starts the app at login, stay quiet.
        if SMAppService.mainApp.status != .enabled { openApp() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !(mainWindow?.isVisible ?? false) { openApp() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let id = currentLedgerId {
            Health.ledger.finish(id: id, reason: .quit, detail: "The app was quit while recording.")
            currentLedgerId = nil
        }
        defer { Log.endSession() }
        // Best effort: stop capture so the files are closed properly.
        // Detached so it doesn't need the main thread, which is waiting right here.
        let done = DispatchSemaphore(value: 0)
        let recorder = self.recorder
        Task.detached {
            await recorder.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }

    // MARK: - Notifications

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { self.openApp() }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
            self.beginRecording(call, manual: false)
        }
        model.onRecordNow = { [weak self] in
            self?.beginRecording(DetectedCall(app: "Manual", windowTitle: ""), manual: true)
        }
        model.onStop = { [weak self] in self?.endRecording() }
        model.onIgnore = { [weak self] in
            guard let self else { return }
            if case .callFound(let call) = self.model.state { self.dismissedCall = call }
            self.model.client = ""
            self.model.state = .idle
        }
        model.onRevealLast = { [weak self] in self?.revealLastRecording() }
        model.onAsk = { [weak self] question in self?.ask(question) }
        model.onOpenApp = { [weak self] section in self?.openApp(section) }
        model.onTogglePanel = { [weak self] in self?.togglePanel() }
        model.onPrepare = { [weak self] event in self?.calendar.prepare(event, notify: false) }
        model.onConnectCalendar = { [weak self] in self?.calendar.connect() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Meeting Agent")
        statusItem = item

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Meeting Agent", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let record = NSMenuItem(title: "Start recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        record.target = self
        recordItem = record
        menu.addItem(record)

        let show = NSMenuItem(title: "Show or hide floating window", action: #selector(togglePanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Meeting Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
    }

    /// The menu bar at the top of the screen. The Edit menu is what makes copy and paste work in text fields.
    private func setUpMainMenu() {
        let bar = NSMenu()

        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Meeting Agent", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Meeting Agent", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Meeting Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let search = NSMenuItem(title: "Search Everything…", action: #selector(searchFromMenu), keyEquivalent: "k")
        search.target = self
        edit.addItem(search)
        editItem.submenu = edit

        let recordItem = NSMenuItem()
        bar.addItem(recordItem)
        let recordMenu = NSMenu(title: "Recording")
        let toggleRecording = NSMenuItem(title: "Start or Stop Recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "r")
        toggleRecording.keyEquivalentModifierMask = [.command, .shift]
        toggleRecording.target = self
        recordMenu.addItem(toggleRecording)
        let bookmark = NSMenuItem(title: "Bookmark This Moment", action: #selector(bookmarkFromMenu), keyEquivalent: "b")
        bookmark.keyEquivalentModifierMask = [.command, .shift]
        bookmark.target = self
        recordMenu.addItem(bookmark)
        recordItem.submenu = recordMenu

        let windowItem = NSMenuItem()
        bar.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let home = NSMenuItem(title: "Meeting Agent", action: #selector(openFromMenu), keyEquivalent: "0")
        home.target = self
        window.addItem(home)
        let floating = NSMenuItem(title: "Show or hide floating window", action: #selector(togglePanel), keyEquivalent: "")
        floating.target = self
        window.addItem(floating)
        windowItem.submenu = window
        NSApp.windowsMenu = window

        let helpItem = NSMenuItem()
        bar.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let replay = NSMenuItem(title: "Show the welcome and setup again", action: #selector(replaySetup), keyEquivalent: "")
        replay.target = self
        helpMenu.addItem(replay)
        let feedback = NSMenuItem(title: "Send Feedback…", action: #selector(openFeedbackFromMenu), keyEquivalent: "")
        feedback.target = self
        helpMenu.addItem(feedback)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = bar
    }

    // MARK: - Shortcuts and sleep

    private func registerHotKeys() {
        HotKey.register(id: 1, keyCode: 46) { [weak self] in self?.togglePanel() }      // M
        HotKey.register(id: 2, keyCode: 0) { [weak self] in self?.askHotKey() }          // A
        HotKey.register(id: 3, keyCode: 1) { [weak self] in self?.peekHotKey() }         // S
        HotKey.register(id: 4, keyCode: 15) { [weak self] in self?.toggleRecordingFromMenu() }   // R
        HotKey.register(id: 5, keyCode: 11) { [weak self] in self?.addBookmark() }       // B
    }

    // MARK: - Bookmarks

    @objc private func bookmarkFromMenu() { addBookmark() }

    /// Marks the current moment of the call. The list shows up under "Highlights" when you open the call later.
    private func addBookmark() {
        guard recorder.isRecording, let folder = recorder.folder else { return }
        let items = BookmarkStore.add(at: recorder.elapsed, in: folder)
        model.bookmarkCount = items.count
        Theme.tap()
        NSSound(named: NSSound.Name("Tink"))?.play()
        Log.write("bookmark \(items.count) at \(Transcript.clock(recorder.elapsed))")
    }

    private func askHotKey() {
        if case .recording = model.state {
            model.collapsed = false
            model.panelTab = .ask
            panel?.orderFrontRegardless()
            panel?.makeKey()
            model.focusAsk += 1
        } else {
            openApp(LibraryModel.allKey)
        }
    }

    private func peekHotKey() {
        panel?.orderFrontRegardless()
        model.peek()
    }

    private func observeSleep() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.recorder.isRecording else {
                Log.info("power", "The Mac is going to sleep (not recording)")
                return
            }
            Log.warn("power", "The Mac is going to sleep while recording; stopping and saving")
            if let call = self.currentCall, let id = self.currentLedgerId { self.lastSleepStop = (call, Date(), id) }
            self.endRecording(reason: .sleep, detail: "The Mac went to sleep.")
            self.model.raise(AppAlert(id: "sleep", message: "Recording stopped because your Mac went to sleep. Everything up to then was saved. If the call is still going when it wakes, I'll start again.", isInfo: true))
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.info("power", "The Mac woke up")
            // Give the call app and the network a few seconds, then carry on if the call is still there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, let slept = self.lastSleepStop, Date().timeIntervalSince(slept.at) < 30 * 60 else { return }
                self.lastSleepStop = nil
                guard !self.recorder.isRecording, case .active(let call) = self.detector.state else { return }
                Log.info("power", "The call is still going after waking, so recording again")
                self.beginRecording(call, manual: false, resumeOf: slept.id)
            }
        }
    }

    /// A recording folder with a lock file means the app was closed in the middle of a call.
    private func recoverInterrupted() {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: Log.root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let lock = folder.appendingPathComponent("recording.lock")
            guard fileManager.fileExists(atPath: lock.path) else { continue }
            try? fileManager.removeItem(at: lock)

            // Folder names look like 2026-10-17_1432_Google-Meet.
            let id = folder.lastPathComponent
            let parts = id.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
            var date = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            var app = "Call"
            if parts.count >= 3 {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HHmm"
                if let parsed = formatter.date(from: "\(parts[0])_\(parts[1])") { date = parsed }
                app = parts[2].replacingOccurrences(of: "-", with: " ")
            }
            if !memory.records.contains(where: { $0.id == id }) {
                memory.upsert(CallRecord(id: id, client: MemoryStore.unassigned, date: date, app: app, summary: ""))
            }
            Log.write("recovered an interrupted recording: \(id)")
            model.raise(AppAlert(
                id: "recovered",
                message: "A call from \(date.formatted(date: .abbreviated, time: .shortened)) was cut short (the app closed or the Mac restarted). I kept the transcript and I'm writing the notes. The video may not play.",
                button: "See calls",
                section: LibraryModel.allKey,
                isInfo: true
            ))
            processor.process(folder: folder, wait: false)
        }
        library.reload()
    }

    // MARK: - Detection and recording

    private func handle(_ state: CallState) {
        switch state {
        case .active(let call):
            if wrapUp.isWrappingUp { cancelWrapUp("the call was detected again") }
            guard !recorder.isRecording, call != dismissedCall else { return }
            if autoRecord {
                beginRecording(call, manual: false)
            } else {
                model.pastClients = projects.names(memory: memory, knowledge: knowledge)
                model.state = .callFound(call)
            }
        case .idle:
            dismissedCall = nil
            if recorder.isRecording, !manualRecording {
                beginWrapUp()
            } else if case .callFound = model.state {
                model.client = ""
                model.state = .idle
            }
        }
    }

    private func beginRecording(_ call: DetectedCall, manual: Bool, resumeOf: String? = nil) {
        guard !recorder.isRecording, !recorder.isStarting else { return }
        if resumeOf == nil { resumeCount = 0 }
        let free = Diagnostics.freeBytes(at: Log.root)
        if case .critical(let bytes) = DiskGuard.verdict(freeBytes: free) {
            Log.error("recorder", "Not starting: only \(Diagnostics.gigabytes(bytes)) of disk space is free")
            model.state = .error("There is only \(Diagnostics.gigabytes(bytes)) of free space on this Mac, which is too little to record safely. Free up some space and try again.")
            return
        }
        Task { @MainActor in
            do {
                let speechAllowed = await LiveTranscriber.requestAuthorization()
                speechOn = speechAllowed
                if !speechAllowed {
                    Log.write("speech recognition not allowed: recording without a transcript")
                    model.raise(AppAlert(id: "speech-off", message: "Speech Recognition is off, so this call won't have a live transcript. Switch it on and the next call will.", button: "Fix it", section: LibraryModel.settingsKey))
                }
                recorder.transcriber = speechAllowed ? transcriber : nil
                model.lines = []
                model.partial = [:]
                model.chat = []
                model.bookmarkCount = 0
                model.speakingNow = nil
                model.panelTab = .now
                model.collapsed = false
                chatHistory = []
                recordingStart = Date()

                // If the calendar knows this meeting, use its title and the people invited.
                let event = calendar.currentEvent()
                currentTitle = event?.title
                currentAttendees = event?.people ?? []

                try await recorder.start(call: call)
                manualRecording = manual
                currentCall = call
                wrapUpWarnings = 0
                if let folder = recorder.folder {
                    let id = folder.lastPathComponent
                    currentLedgerId = id
                    Health.ledger.begin(LedgerEntry(id: id, app: call.app, startedAt: Date(), automatic: !manual, resumedFrom: resumeOf, freeGBAtStart: free.map { Double($0) / 1_073_741_824 }))
                    Log.info("recorder", "Recording started: \(manual ? "manual" : "automatic"), \(call.app), window \"\(call.windowTitle)\"\(resumeOf != nil ? ", continuing after an interruption" : "")")
                }
                detector.isRecording = true
                model.state = .recording(call: call, since: Date())
                currentApp = call.app
                currentCallId = recorder.folder?.lastPathComponent
                model.recap = []
                model.suggestions = []
                model.lastSummaryURL = nil
                model.alert = model.alert?.id == "speech-off" ? model.alert : nil
                model.pastClients = projects.names(memory: memory, knowledge: knowledge)
                if model.client.trimmed.isEmpty, let event {
                    let match = calendar.matchProject(for: event)
                    if !match.isEmpty { model.client = match }
                }
                lineCounter = 0
                lastCopilotLine = 0
                copilotFailures = 0
                geminiPauseShown = false
                startCopilot()
                startWatchdog()
                setStatusIcon(recording: true)
                Theme.tap()
            } catch {
                Log.error("recorder", "Could not start recording: \(error.localizedDescription)")
                // A failed start can leave an empty folder with a lock file, which the next launch would treat as a crash.
                if let folder = recorder.folder {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("recording.lock"))
                    if ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
                model.state = .error(error.localizedDescription)
            }
        }
    }

    private func endRecording(reason: EndReason = .manualStop, detail: String = "") {
        cancelWrapUp(nil)
        let ledgerId = currentLedgerId
        currentLedgerId = nil
        let length = Int(recorder.elapsed)
        Task { @MainActor in
            let folder = await recorder.stop()
            detector.isRecording = false
            manualRecording = false
            setStatusIcon(recording: false)
            stopWatchdog()
            if let ledgerId, folder != nil {
                Health.ledger.finish(id: ledgerId, reason: reason, detail: detail)
                let line = "Recording ended after \(length / 60) min \(length % 60) s: \(reason.plain)\(detail.isEmpty ? "" : " (\(detail))")"
                if reason.isNormal { Log.info("recorder", line) } else { Log.warn("recorder", line) }
            }
            if let folder {
                lastFolder = folder
                finishCall(folder: folder)
                let name = folder.lastPathComponent
                model.lastSaved = name
                // The "Saved" link fades away after a minute.
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    if self?.model.lastSaved == name { self?.model.lastSaved = nil }
                }
            }
            stopCopilot()
            model.state = .idle
        }
    }

    /// macOS stopped the capture, or sound stopped arriving. Save what there is and, if the call is still going, start again.
    private func recordingEndedUnexpectedly(_ message: String, reason: EndReason = .streamError) {
        cancelWrapUp(nil)
        let ledgerId = currentLedgerId
        let call = currentCall
        let wasManual = manualRecording
        currentLedgerId = nil
        if let ledgerId { Health.ledger.finish(id: ledgerId, reason: reason, detail: message) }
        detector.isRecording = false
        manualRecording = false
        setStatusIcon(recording: false)
        stopWatchdog()
        if let folder = recorder.folder {
            lastFolder = folder
            model.lastSaved = folder.lastPathComponent
            finishCall(folder: folder)
        }
        stopCopilot()

        let callStillThere = wasManual || detector.state != .idle
        if let call, let ledgerId,
           ResumePolicy().shouldResume(reason: reason, resumesSoFar: resumeCount, callStillLive: callStillThere, wasStoppedByUser: false) {
            resumeCount += 1
            Log.warn("recorder", "Starting a new recording to continue this call (attempt \(resumeCount) of \(ResumePolicy().maxResumes))")
            model.state = .idle
            model.raise(AppAlert(id: "resumed", message: "The recording was interrupted (\(reason.plain)), so I started a new one. This call will be saved in more than one part.", isInfo: true))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.beginRecording(call, manual: wasManual, resumeOf: ledgerId)
            }
            return
        }
        Log.error("recorder", "Recording ended early and was not restarted: \(reason.plain). \(message)")
        model.state = .error("Recording stopped early (\(message)). What was captured is saved in Movies > MeetingAgent. Use Settings > Recorder health to send a report.")
    }

    // MARK: - When the call looks over

    /// The detector lost the call. That can mean it really ended, or just that the tab lost focus or the mic was
    /// released for a moment. The app never stops by itself: it asks, and the person decides.
    private func beginWrapUp() {
        guard wrapUpTimer == nil else { return }
        wrapUp.reset()
        wrapUpWarnings = 0
        lastAskedAt = nil
        let heard = recorder.activity.lastSound.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "none yet"
        Log.warn("recorder", "The call looks over (the detector lost it). Will ask before stopping. Last sound heard: \(heard)")
        wrapUpTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.wrapUpTick() }
        wrapUpTick()
    }

    private func wrapUpTick() {
        guard recorder.isRecording, !manualRecording else { cancelWrapUp(nil); return }
        let live = detector.state != .idle
        switch wrapUp.update(now: Date(), callIsLive: live, lastSound: recorder.activity.lastSound) {
        case .carryOn:
            if live { cancelWrapUp("the call came back") }
            else if wrapUp.snoozedUntil != nil { model.clearAlert("wrapup") }
        case .ask:
            // Ask now, then remind every two minutes if the question is still unanswered or was dismissed.
            let due = lastAskedAt.map { Date().timeIntervalSince($0) >= 120 } ?? true
            guard due else { return }
            if wrapUpWarnings == 0 { Log.warn("recorder", "Asking the person whether to end the recording") }
            wrapUpWarnings += 1
            lastAskedAt = Date()
            model.collapsed = false
            model.raise(AppAlert(id: "wrapup", message: "This call looks like it has ended. Do you want to end the recording?", button: "End recording", section: "§action:end", button2: "Keep recording", section2: "§action:keep"))
            Theme.tap()
        }
    }

    private func cancelWrapUp(_ why: String?) {
        let was = wrapUpTimer != nil
        wrapUpTimer?.invalidate()
        wrapUpTimer = nil
        wrapUp.reset()
        lastAskedAt = nil
        model.clearAlert("wrapup")
        if was, let why { Log.info("recorder", "Question about ending the recording closed: \(why)") }
    }

    /// The person pressed "Keep recording". Ask again only if the call is still missing after a while.
    private func keepRecording() {
        guard recorder.isRecording else { return }
        wrapUp.keepRecording(now: Date())
        lastAskedAt = nil
        model.clearAlert("wrapup")
        Log.info("recorder", "The person chose to keep recording. Will not ask again for \(Int(wrapUp.snooze / 60)) minutes.")
        model.raise(AppAlert(id: "kept", message: "Okay, still recording. I'll ask again in \(Int(wrapUp.snooze / 60)) minutes if the call hasn't come back. Press Stop any time.", isInfo: true))
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.model.clearAlert("kept") }
    }

    /// The person pressed "End recording".
    private func confirmEnd() {
        guard recorder.isRecording else { return }
        Log.info("recorder", "The person confirmed that the call is over")
        endRecording(reason: .callEnded, detail: "you confirmed the call was over")
    }

    /// Buttons in banners call these through the section field: "§action:keep".
    private func perform(action: String) {
        switch action {
        case "keep": keepRecording()
        case "end": confirmEnd()
        case "update": Task { @MainActor in UpdateChecker.shared.download() }
        case let other where other.hasPrefix("voices:"):
            let id = String(other.dropFirst("voices:".count))
            if let call = memory.records.first(where: { $0.id == id }) {
                library.detailCall = call
                library.selection = LibraryModel.homeKey
            }
            openApp()
        default: Log.warn("app", "Unknown action \(action)")
        }
    }

    private func setStatusIcon(recording: Bool) {
        let name = recording ? "record.circle.fill" : "record.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Agent")
        statusItem?.button?.contentTintColor = recording ? .systemRed : nil
        recordItem?.title = recording ? "Stop recording" : "Start recording"
    }

    // MARK: - Watching for trouble

    private func startWatchdog() {
        systemFixTries = 0
        lastSystemFix = Date.distantPast
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        for id in ["no-speech", "screen", "speech-off", "copilot", "wrapup", "disk-low", "system-silent"] { model.clearAlert(id) }
    }

    private func watchdogTick() {
        guard case .recording = model.state else { return }
        perfTicks += 1
        if perfTicks % 3 == 0 { Log.info("perf", Performance.line()) }
        if let why = recorder.activity.stall() {
            Log.error("recorder", "The capture has gone quiet: \(why). Received: \(recorder.activity.summary())")
            Task { @MainActor in
                _ = await self.recorder.stop()
                self.recordingEndedUnexpectedly(why, reason: .stalled)
            }
            return
        }
        if recorder.activity.neverReceivedAudio() {
            Log.warn("recorder", "No audio has arrived for over a minute. Check Microphone and Screen Recording permissions. \(recorder.activity.summary())")
        }
        if recorder.activity.systemSilentWhileMicTalks() {
            if systemFixTries < 3, Date().timeIntervalSince(lastSystemFix) > 60 {
                systemFixTries += 1
                lastSystemFix = Date()
                Log.warn("recorder", "The call audio has been blank for over a minute while your microphone hears talking (try \(systemFixTries)). \(recorder.activity.summary())")
                Task { await self.recorder.reconnectSystemAudio() }
            }
            model.raise(AppAlert(id: "system-silent", message: "I can't record the other people's sound right now, only what your microphone hears. Check that the call audio is playing through the Mac's sound output. If you switched speakers or headphones, switch back. I'm trying to reconnect.", isInfo: false))
        } else {
            model.clearAlert("system-silent")
        }
        switch DiskGuard.verdict(freeBytes: Diagnostics.freeBytes(at: Log.root)) {
        case .critical(let bytes):
            Log.error("disk", "Only \(Diagnostics.gigabytes(bytes)) free. Stopping the recording so the files are not damaged.")
            endRecording(reason: .diskFull, detail: "\(Diagnostics.gigabytes(bytes)) free")
            model.raise(AppAlert(id: "disk", message: "Recording stopped because this Mac is almost out of space (\(Diagnostics.gigabytes(bytes)) left). What was recorded is saved. Free up some space.", isInfo: false))
            return
        case .low(let bytes):
            if !lowDiskShown {
                lowDiskShown = true
                Log.warn("disk", "Free space is getting low: \(Diagnostics.gigabytes(bytes))")
                model.raise(AppAlert(id: "disk-low", message: "This Mac is running low on space (\(Diagnostics.gigabytes(bytes)) left). A long recording could be cut short.", isInfo: false))
            }
        case .fine:
            lowDiskShown = false
            model.clearAlert("disk-low")
        }
        if !CGPreflightScreenCaptureAccess() {
            model.raise(AppAlert(id: "screen", message: "Screen Recording was switched off, so this recording may have stopped. Turn it back on, then quit and reopen Meeting Agent.", button: "Fix it", section: LibraryModel.homeKey))
            return
        }
        model.clearAlert("screen")
        if speechOn, lineCounter == 0, Date().timeIntervalSince(recordingStart) > 90 {
            model.raise(AppAlert(id: "no-speech", message: "I'm not hearing any speech yet. Check that the call audio is playing and that nobody is muted. The recording itself is still running."))
        } else if lineCounter > 0 {
            model.clearAlert("no-speech")
        }
    }

    // MARK: - Live recap and suggestions

    private static let copilotSystem = """
    You quietly coach the user during a live call. "You" is the user and "Them" is everyone else. \
    The text is automatic speech recognition, so expect small mistakes. You get the last few minutes of the call, \
    and sometimes background from the user's notes, files and earlier calls, and the promises still open for this project. \
    Reply with JSON only, in exactly this shape: {"recap": ["..."], "cards": [{"kind": "ask", "text": "...", "why": "..."}], "project": ""}. \
    "project" is only used when you are given a list of the user's projects and the call is not yet filed under one: \
    put the exact name of the one project this call is clearly about, or an empty string if you are not sure. \
    "recap" has at most 3 very short bullets covering the last 2 to 3 minutes, so a user who zoned out can catch up in five seconds. \
    "cards" has at most 2 items and may be empty. kind "ask" is a sharp question the user could ask next. \
    kind "pushback" is a point worth challenging, with the reason. \
    kind "flag" is something that contradicts what was said earlier on this call or in an earlier call, an open promise that is relevant right now, or a question aimed at the user that is still unanswered. \
    Only add a card when it would really help right now. Never invent facts that are not in the text you were given. \
    "text" is under 25 words and "why" is under 20 words and says where the point comes from, \
    for example "from the Acme proposal", "from your call on 12 Oct" or "earlier in this call". Write in English.
    """

    private func startCopilot() {
        copilotTimer?.invalidate()
        copilotTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.copilotTick()
        }
    }

    private func stopCopilot() {
        copilotTimer?.invalidate()
        copilotTimer = nil
        model.recap = []
        model.suggestions = []
    }

    private func copilotTick() {
        guard case .recording = model.state, model.copilotOn, !copilotBusy,
              lineCounter != lastCopilotLine,
              let key = AIAccess.key(project: model.client, projects: projects) else { return }
        // The on-device model uses a lot of this Mac's memory and processor while the call is running,
        // so on-device suggestions come only every few minutes.
        if key == AIAccess.localKey {
            if Date().timeIntervalSince(lastLocalTick) < 180 { return }
            lastLocalTick = Date()
        }
        // A free Gemini key allows only a handful of requests a day. Go slowly and leave room for the summary.
        if key != AIAccess.localKey, !key.hasPrefix("sk-ant-") {
            if !GeminiBudget.liveSuggestionsAllowed {
                if !geminiPauseShown {
                    geminiPauseShown = true
                    model.raise(AppAlert(id: "copilot", message: "Live suggestions are paused to save your free Gemini limit for the call summary. Claude has no tight daily limit.", button: "Change AI", section: LibraryModel.settingsKey, isInfo: true))
                }
                return
            }
            if Date().timeIntervalSince(lastGeminiTick) < 120 { return }
            lastGeminiTick = Date()
        }
        copilotBusy = true
        lastCopilotLine = lineCounter

        let start = recordingStart
        func stamp(_ date: Date) -> String {
            let seconds = max(0, Int(date.timeIntervalSince(start)))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        let cutoff = Date().addingTimeInterval(-360)
        var transcript = model.lines
            .filter { $0.time > cutoff }
            .map { "[\(stamp($0.time))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let transcriptLimit = key == AIAccess.localKey ? 4_000 : 12_000
        if transcript.count > transcriptLimit { transcript = String(transcript.suffix(transcriptLimit)) }
        let known = projects.names(memory: memory, knowledge: knowledge)
        let projectHint = (model.client.trimmed.isEmpty && !known.isEmpty)
            ? "The user's projects: \(known.joined(separator: "; ")). This call is not filed under one yet.\n\n"
            : ""
        let found = retriever.context(
            query: String(transcript.suffix(2000)),
            client: model.client,
            excluding: currentCallId,
            maxChars: key == AIAccess.localKey ? 2500 : 9000,
            cloud: key != AIAccess.localKey
        )
        let promises = model.client.trimmed.isEmpty ? "" : commitments.openLines(project: model.client, memory: memory)
        let earlier = found.text
        let prompt = (earlier.isEmpty ? "" : "Background from the user's notes, files and earlier calls:\n\(earlier)\n\n")
            + (promises.isEmpty ? "" : "Promises still open for this project:\n\(promises)\n\n")
            + projectHint
            + "Current call, the last few minutes (time in call: \(stamp(Date()))):\n\(transcript)\n\nReturn the JSON now."

        Task { @MainActor in
            defer { copilotBusy = false }
            do {
                let reply = try await ChatService.complete(key: key, system: AppDelegate.copilotSystem, prompt: prompt, json: true, maxTokens: 700)
                copilotFailures = 0
                model.clearAlert("copilot")
                applyCopilot(reply)
            } catch {
                Log.write("copilot: \(error.localizedDescription)")
                copilotFailures += 1
                if case ChatError.badKey = error {
                    if key != AIAccess.localKey { Keychain.delete() }
                    model.hasKey = false
                    model.raise(AppAlert(id: "key", message: "Your AI key was rejected, so live suggestions have stopped. Paste a new one in Settings.", button: "Fix it", section: LibraryModel.settingsKey))
                } else if copilotFailures >= 3 {
                    model.raise(AppAlert(id: "copilot", message: "Live suggestions are paused: \(error.localizedDescription)", button: "Check AI settings", section: LibraryModel.settingsKey))
                }
            }
        }
    }

    private func applyCopilot(_ reply: String) {
        guard case .recording = model.state, let json = CallProcessor.jsonObject(from: reply) else {
            Log.write("copilot: could not read the reply")
            return
        }
        let recap = (json["recap"] as? [String] ?? []).map { $0.trimmed }.filter { !$0.isEmpty }
        model.recap = Array(recap.prefix(3))

        let cards: [Suggestion] = (json["cards"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let body = (dict["text"] as? String)?.trimmed, !body.isEmpty else { return nil }
            var kind = ((dict["kind"] as? String) ?? "ask").lowercased()
            if !["ask", "pushback", "flag"].contains(kind) { kind = "ask" }
            return Suggestion(kind: kind, text: body, why: ((dict["why"] as? String) ?? "").trimmed)
        }
        if !cards.isEmpty { model.suggestions = Array(cards.prefix(2)) }

        if model.client.trimmed.isEmpty,
           let guess = (json["project"] as? String)?.trimmed, !guess.isEmpty,
           let match = projects.names(memory: memory, knowledge: knowledge).first(where: { $0.lowercased() == guess.lowercased() }) {
            model.client = match
            Log.write("copilot: this call looks like it belongs to project \(match)")
        }
    }

    // MARK: - After the call

    private func finishCall(folder: URL) {
        stopCopilot()
        Theme.tap()
        let id = folder.lastPathComponent
        let typed = model.client.trimmed
        let client = typed.isEmpty ? MemoryStore.unassigned : projects.canonical(typed, memory: memory, knowledge: knowledge)
        if client != MemoryStore.unassigned { projects.ensure(client) }
        model.client = ""
        let base = CallRecord(
            id: id,
            client: client,
            date: recordingStart,
            app: currentApp,
            summary: "",
            title: currentTitle,
            attendees: currentAttendees.isEmpty ? nil : currentAttendees
        )
        memory.upsert(base)
        library.reload()
        processor.process(folder: folder, wait: true)
    }

    // MARK: - Menu actions

    @objc private func openFromMenu() { openApp() }
    @objc private func openSettingsFromMenu() { openApp(LibraryModel.settingsKey) }
    @objc private func openFeedbackFromMenu() { openApp(LibraryModel.feedbackKey) }

    @objc private func searchFromMenu() {
        openApp()
        library.showSearch = true
    }

    @objc private func toggleRecordingFromMenu() {
        if recorder.isRecording {
            endRecording()
        } else if case .callFound(let call) = model.state {
            beginRecording(call, manual: false)
        } else {
            beginRecording(DetectedCall(app: "Manual", windowTitle: ""), manual: true)
        }
    }

    // MARK: - Ask the call

    private func ask(_ question: String) {
        guard let key = AIAccess.key(project: model.client, projects: projects) else {
            model.hasKey = false
            return
        }
        guard !model.asking else { return }
        model.chat.append(ChatMessage(fromYou: true, text: question))
        model.asking = true

        let start = recordingStart
        func stamp(_ date: Date) -> String {
            let seconds = max(0, Int(date.timeIntervalSince(start)))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        var transcript = model.lines.map { "[\(stamp($0.time))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        for speaker in ["Them", "You"] {
            if let text = model.partial[speaker], !text.isEmpty {
                transcript += "\n[\(stamp(Date()))] \(speaker): \(text)"
            }
        }
        if transcript.count > 40_000 { transcript = String(transcript.suffix(40_000)) }
        let now = stamp(Date())
        let history = chatHistory
        let found = retriever.context(
            query: question + " " + String(transcript.suffix(1000)),
            client: model.client,
            excluding: currentCallId,
            maxChars: 9000,
            cloud: key != AIAccess.localKey
        )
        let memoryText = found.text

        Task { @MainActor in
            do {
                let answer = try await ChatService.ask(key: key, transcript: transcript, now: now, memory: memoryText, history: history, question: question)
                chatHistory.append((question, answer))
                let used = citedSources(in: answer, from: found.sources)
                model.chat.append(ChatMessage(fromYou: false, text: answer, sources: used))
            } catch {
                if case ChatError.badKey = error {
                    if key != AIAccess.localKey { Keychain.delete() }
                    model.hasKey = false
                }
                model.chat.append(ChatMessage(fromYou: false, text: error.localizedDescription, isError: true))
            }
            model.asking = false
        }
    }

    /// Opens the main window, optionally on a given section such as "§settings".
    /// When the app is opened straight from the installer disk image, offer to copy it into Applications.
    /// Returns true when it relaunched from Applications and this copy should quit.
    private func offerMoveToApplications() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Meeting Agent to your Applications folder?"
        alert.informativeText = "It works best from Applications. macOS remembers its permissions there, and you can find it in Launchpad and Spotlight."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let destination = "/Applications/Meeting Agent.app"
        do {
            if FileManager.default.fileExists(atPath: destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try runTool("/usr/bin/ditto", [path, destination])
            // You have already chosen to open this app, so clear the "downloaded from the internet" flag on the copy.
            _ = try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination])
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: destination), configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move the app"
            failure.informativeText = "Drag Meeting Agent into your Applications folder yourself, then open it from there."
            failure.runModal()
            return false
        }
    }

    private func runTool(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "MeetingAgent", code: Int(process.terminationStatus))
        }
    }

    private func openApp(_ section: String? = nil) {
        if let section, section.hasPrefix("§action:") {
            perform(action: String(section.dropFirst("§action:".count)))
            return
        }
        if let section { library.selection = section }
        library.reload()
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainView(model: library, agent: model))
            let window = NSWindow(contentViewController: host)
            window.title = "Meeting Agent"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1020, height: 680))
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func replaySetup() {
        UserDefaults.standard.set(0, forKey: "onboardingPage")
        UserDefaults.standard.set(false, forKey: "onboarded")
        openApp(nil)
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func revealLastRecording() {
        guard let lastFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFolder])
    }
}
