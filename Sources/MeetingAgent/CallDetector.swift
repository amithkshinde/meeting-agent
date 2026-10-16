import AppKit
import CoreAudio
import CoreGraphics

struct DetectedCall: Equatable {
    let app: String
    let windowTitle: String
}

enum CallState: Equatable {
    case idle
    case active(DetectedCall)
}

/// Spots a call in progress without a calendar event or a known link.
///
/// Two signals are combined: is the default microphone running somewhere on the system, and does an
/// on-screen window look like a call. Window titles of other apps are only readable once the app has
/// Screen Recording permission, so detection improves after the first permission grant.
///
/// Known limits of this first version: a browser only exposes its active tab's title, and a call
/// window that is minimised or on another Space is not seen. Reading the browser URL and the call
/// controls on screen are planned follow-ups.
final class CallDetector {
    var onChange: ((CallState) -> Void)?

    /// Set while recording. The microphone is then held by this app, so it no longer says anything
    /// about whether the call is still going.
    var isRecording = false

    private(set) var state: CallState = .idle
    private var timer: Timer?
    private var hits = 0
    private var misses = 0

    private let startAfterHits = 2   // about 3 s of agreement before announcing a call
    private let endAfterMisses = 3   // about 4.5 s of silence before calling it over

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let micOn = isRecording || Self.microphoneInUse()
        if let call = Self.findCallWindow(micOn: micOn) {
            hits += 1
            misses = 0
            if hits >= startAfterHits, state == .idle {
                state = .active(call)
                Log.write("call detected: \(call.app) | window: \"\(call.windowTitle)\" | mic: \(micOn)")
                onChange?(state)
            }
        } else {
            misses += 1
            hits = 0
            if misses >= endAfterMisses, state != .idle {
                state = .idle
                Log.write("call ended (no call window for \(endAfterMisses) checks)")
                onChange?(state)
            }
        }
    }

    // MARK: - Signals

    /// True when the default input device is being used by any process.
    static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != 0 else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return result == noErr && running != 0
    }

    static func findCallWindow(micOn: Bool) -> DetectedCall? {
        for window in onScreenWindows() where window.layer == 0 {
            if let app = classify(owner: window.owner, title: window.title, micOn: micOn) {
                return DetectedCall(app: app, windowTitle: window.title)
            }
        }
        return nil
    }

    /// Every normal on-screen window as (owner, title). Used by detection and by the "Log visible
    /// windows" menu item, which helps tune the rules against real calls.
    static func onScreenWindows() -> [(owner: String, title: String, layer: Int)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.map { info in
            (
                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                layer: info[kCGWindowLayer as String] as? Int ?? 0
            )
        }
    }

    // MARK: - Rules

    private static let browsers = [
        "google chrome", "safari", "arc", "microsoft edge", "brave browser",
        "firefox", "chromium", "vivaldi", "opera",
    ]

    /// Maps a window to a call app name, or nil when it does not look like a call.
    static func classify(owner: String, title: String, micOn: Bool) -> String? {
        let o = owner.lowercased()
        let t = title.lowercased()

        if o.contains("zoom"), t.contains("zoom meeting") || t.contains("zoom webinar") {
            return "Zoom"
        }

        if browsers.contains(where: { o.contains($0) }) {
            if t.hasPrefix("meet - ") || t.hasPrefix("meet – ") || t.contains("meet.google.com") {
                return "Google Meet"
            }
            if micOn, t.contains("| microsoft teams") {
                return "Microsoft Teams (web)"
            }
        }

        if micOn {
            if o.contains("microsoft teams") { return "Microsoft Teams" }
            if o == "slack", t.contains("huddle") { return "Slack huddle" }
            if o == "facetime" { return "FaceTime" }
            if o.contains("webex") { return "Webex" }
        }
        return nil
    }
}
