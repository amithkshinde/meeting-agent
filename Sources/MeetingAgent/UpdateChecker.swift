import AppKit

/// Looks for a newer version on GitHub and installs it with one click: it downloads the right installer,
/// swaps the app where it lives, and reopens it. If that isn't possible it opens the installer for a manual drag.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)     // the new version number
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var latest: ReleaseInfo?
    var onAlert: ((AppAlert) -> Void)?
    private var timer: Timer?

    private var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Checks soon after launch, then twice a day while the app stays open.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in Task { await self?.check(manual: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        state = .checking
        let url = URL(string: "https://api.github.com/repos/\(FeedbackConfig.repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MeetingAgent/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                // No release has been published yet.
                Log.info("update", "No release published yet")
                state = .upToDate
                return
            }
            guard code == 200, let release = ReleaseInfo.parse(data) else {
                Log.warn("update", "Update check got HTTP \(code)")
                state = .failed("GitHub answered \(code)")
                return
            }
            latest = release
            if UpdateDecision.isNewer(latest: release.tag, installed: installedVersion) {
                Log.info("update", "Version \(release.version) is available (installed \(installedVersion))")
                state = .available(release.version.description)
                remind(release, force: manual)
            } else {
                Log.info("update", "Up to date (\(installedVersion))")
                state = .upToDate
            }
        } catch {
            Log.warn("update", "Update check failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    private func remind(_ release: ReleaseInfo, force: Bool) {
        let key = "updateReminded-\(release.tag)"
        let last = UserDefaults.standard.object(forKey: key) as? Date
        guard force || UpdateDecision.shouldRemind(lastReminded: last) else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let what = release.headline.isEmpty ? "" : " \(release.headline)"
        onAlert?(AppAlert(
            id: "update",
            message: "Meeting Agent \(release.version) is ready (you have \(installedVersion)).\(what)",
            button: "Download",
            section: "§action:update",
            isInfo: true
        ))
    }

    /// Set by the app: true while a call is being recorded, so an update never restarts the app mid-call.
    var isRecording: () -> Bool = { false }

    /// Installs the new version by itself: downloads the installer, swaps the app where it lives, and reopens it.
    /// If that can't be done (a Mac where the app folder isn't writable, or something fails), the installer is opened instead.
    func download() {
        guard let release = latest else { return }
        guard let installer = release.installer(appleSilicon: isAppleSilicon) else {
            if let page = release.pageURL {
                Log.warn("update", "No installer for this chip in the release; opening the release page")
                NSWorkspace.shared.open(page)
            }
            return
        }
        if isRecording() {
            onAlert?(AppAlert(id: "update", message: "A call is being recorded. Update once it ends, so the recording isn't interrupted.", isInfo: true))
            return
        }
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard !appPath.hasPrefix("/Volumes/"), !appPath.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: parent) else {
            openInstaller(installer)
            return
        }
        onAlert?(AppAlert(id: "update", message: "Downloading Meeting Agent \(release.version). The app will close and reopen by itself when it is ready.", isInfo: true))
        Task { @MainActor in
            do {
                let script = try await Self.prepareInPlaceUpdate(installer: installer, appPath: appPath)
                if self.isRecording() {
                    self.onAlert?(AppAlert(id: "update", message: "A call started while the update was downloading. It will install the next time you press Download.", isInfo: true))
                    return
                }
                Log.info("update", "Replacing the app with version \(release.version)")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier)]
                try task.run()
                NSApp.terminate(nil)
            } catch {
                Log.warn("update", "Automatic update failed (\(error.localizedDescription)); opening the installer")
                self.openInstaller(installer)
            }
        }
    }

    private func openInstaller(_ installer: URL) {
        Log.info("update", "Downloading \(installer.lastPathComponent)")
        NSWorkspace.shared.open(installer)
        onAlert?(AppAlert(
            id: "update",
            message: "Downloading. When it finishes, open the .dmg and drag Meeting Agent onto Applications, then choose Replace. Your calls and settings stay.",
            isInfo: true
        ))
    }

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw UpdateError(message: "\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))") }
    }

    /// Downloads and unpacks the new app next to a small script that swaps it in once this app has quit.
    private nonisolated static func prepareInPlaceUpdate(installer: URL, appPath: String) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MeetingAgentUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, response) = try await URLSession.shared.download(from: installer)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "the download did not complete") }
        let dmg = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: downloaded, to: dmg)

        let mount = work.appendingPathComponent("disk", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let staged = work.appendingPathComponent("Meeting Agent.app", isDirectory: true)
        try run("/usr/bin/ditto", [mount.appendingPathComponent("Meeting Agent.app").path, staged.path])
        guard fm.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/MeetingAgent").path) else {
            throw UpdateError(message: "the installer did not contain the app")
        }

        let script = work.appendingPathComponent("swap.sh")
        let text = """
        #!/bin/sh
        # Waits for Meeting Agent to quit, swaps in the new copy, and opens it. Puts the old copy back if anything fails.
        while kill -0 "$1" 2>/dev/null; do sleep 0.5; done
        DEST="\(appPath)"
        NEW="\(staged.path)"
        OLD="$DEST.old-update"
        rm -rf "$OLD"
        if mv "$DEST" "$OLD" && mv "$NEW" "$DEST"; then
          xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
          rm -rf "$OLD"
        else
          [ -d "$OLD" ] && [ ! -d "$DEST" ] && mv "$OLD" "$DEST"
        fi
        open "$DEST"
        rm -rf "\(work.path)"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        return script
    }
}
