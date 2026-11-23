import AppKit
import CoreGraphics

/// Keeps Screen Recording working after an update or reinstall without the person doing anything in Settings.
///
/// macOS ties that permission to the app's exact signature. A build signed without a permanent certificate
/// has a new signature every time, so the switch the person turned on for the old copy means nothing to the new one,
/// and Settings keeps showing "on" while the app is refused. When that happens, the stale entry is cleared once per
/// installed build so the normal macOS permission prompt appears fresh, and it can then be allowed in one click.
enum ScreenAccessHealer {
    private static let key = "screenAccessHealedFor"

    /// Changes whenever a different build is installed.
    static var buildStamp: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var modified = ""
        if let path = Bundle.main.executablePath,
           let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            modified = String(Int(date.timeIntervalSince1970))
        }
        return "\(version)-\(modified)"
    }

    /// Clears a leftover permission entry, once for this build, if macOS is refusing Screen Recording.
    /// Returns true when it cleared one, so the caller should ask again.
    @discardableResult
    static func healIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            UserDefaults.standard.set(buildStamp, forKey: key)
            return false
        }
        guard UserDefaults.standard.string(forKey: key) != buildStamp else { return false }
        UserDefaults.standard.set(buildStamp, forKey: key)
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleID]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            Log.info("permissions", "Cleared the old Screen Recording entry for this build (exit \(task.terminationStatus))")
            return task.terminationStatus == 0
        } catch {
            Log.warn("permissions", "Could not clear the old Screen Recording entry: \(error.localizedDescription)")
            return false
        }
    }

    /// Opens a fresh copy of the app and quits this one, which is what macOS needs after Screen Recording is allowed.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
