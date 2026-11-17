import AppKit

/// Looks for a newer version on GitHub and offers a one-click download of the right installer.
/// Nothing is installed automatically: the person opens the download and drags the app into Applications.
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

    /// Opens the installer for this Mac, or the release page if there is no matching file.
    func download() {
        guard let release = latest else { return }
        if let installer = release.installer(appleSilicon: isAppleSilicon) {
            Log.info("update", "Downloading \(installer.lastPathComponent)")
            NSWorkspace.shared.open(installer)
            onAlert?(AppAlert(
                id: "update",
                message: "Downloading. When it finishes, open the .dmg and drag Meeting Agent onto Applications, then choose Replace. Your calls and settings stay.",
                isInfo: true
            ))
        } else if let page = release.pageURL {
            Log.warn("update", "No installer for this chip in the release; opening the release page")
            NSWorkspace.shared.open(page)
        }
    }
}
