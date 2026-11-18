import Foundation
import FluidAudio

/// Settings and storage for voice recognition. Voice fingerprints are personal data: they stay on this Mac,
/// in a file only this account can read, and can be deleted in Settings.
enum Voices {
    /// Names the speech model that made the fingerprints. Fingerprints are never compared across models.
    static let model = "fluidaudio-offline-pyannote-v1"
    static let onKey = "voiceRecognitionOn"
    static let crashKey = "voiceRecognitionCrashed"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }

    /// True when a previous attempt never finished, so recognition was switched off to protect the app.
    static var crashed: Bool {
        get { UserDefaults.standard.bool(forKey: crashKey) }
        set { UserDefaults.standard.set(newValue, forKey: crashKey) }
    }

    static let library: VoiceLibrary = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingAgent", isDirectory: true)
        return VoiceLibrary(url: support.appendingPathComponent("voices.json"))
    }()

    private static var lockURL: URL { Log.folder.appendingPathComponent("diarizing.lock") }

    /// Call before the heavy step. Returns false if the last attempt never finished (the app crashed or was
    /// force quit in the middle), in which case recognition is turned off until the person turns it back on.
    static func beginAttempt() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: lockURL.path) {
            try? fm.removeItem(at: lockURL)
            crashed = true
            isOn = false
            Log.error("voices", "Voice recognition did not finish last time, so it is switched off. It can be turned back on in Settings.")
            return false
        }
        fm.createFile(atPath: lockURL.path, contents: Data())
        return true
    }

    static func endAttempt() {
        try? FileManager.default.removeItem(at: lockURL)
    }
}

/// Works out who spoke when, and gives each stretch of speech a voice fingerprint.
enum VoiceEngine {
    /// The first call downloads the models (a few hundred MB, once). Runs off the main thread.
    /// `minSpeakers` asks for at least that many voices, used when the call screen showed more people than were found.
    static func diarize(file: URL, minSpeakers: Int? = nil) async throws -> [RawVoiceSegment] {
        var config = OfflineDiarizerConfig.default
        if let minSpeakers { config.clustering.minSpeakers = minSpeakers }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(file)
        return result.segments.map {
            RawVoiceSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), embedding: $0.embedding)
        }
    }
}
