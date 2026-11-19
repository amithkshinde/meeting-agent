import AVFoundation
import FluidAudio

/// What the transcription engine is doing, in words the Settings page and reports can show.
enum TranscriptionStatus {
    static var current = "Parakeet: not set up yet"
    static var summary: String { current }
}

/// Parakeet speech recognition (NVIDIA Parakeet TDT v3), run on this Mac with Core ML through FluidAudio.
/// The model is about 480 MB and is downloaded once, the first time it is needed. After that nothing leaves the Mac.
/// It listens to the two audio files a call leaves behind: mic.m4a becomes "You" and system.m4a becomes "Them".
@MainActor
final class ParakeetEngine: ObservableObject {
    static let shared = ParakeetEngine()

    enum State: Equatable {
        case idle
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { TranscriptionStatus.current = Self.describe(state) }
    }

    /// The sentences from the last call that was transcribed (your mic, and everyone else), so voices can be matched to them.
    private(set) var lastTracks: (you: [Utterance], them: [Utterance])?

    private var manager: AsrManager?
    private var loading: Task<Bool, Never>?

    static func describe(_ state: State) -> String {
        switch state {
        case .idle: return "Parakeet: not downloaded yet"
        case .downloading(let fraction): return "Parakeet: downloading the model (\(Int(fraction * 100))%)"
        case .ready: return "Parakeet: ready (runs on this Mac)"
        case .failed(let why): return "Parakeet: unavailable (\(why))"
        }
    }

    var isReady: Bool { state == .ready }

    /// Downloads (first time only) and loads the model. Safe to call many times; it only works once.
    @discardableResult
    func prepare() async -> Bool {
        if manager != nil { return true }
        if let loading { return await loading.value }
        let task = Task { @MainActor () -> Bool in
            self.state = .downloading(0)
            Log.info("parakeet", "Preparing the Parakeet model (\(Diagnostics.chip()))")
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in ParakeetEngine.shared.noteProgress(fraction) }
                })
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                self.manager = manager
                self.state = .ready
                Log.info("parakeet", "Parakeet is ready")
                return true
            } catch {
                self.state = .failed(error.localizedDescription)
                Log.error("parakeet", "Could not set up Parakeet: \(error.localizedDescription)")
                return false
            }
        }
        loading = task
        let ok = await task.value
        loading = nil
        return ok
    }

    private var lastLoggedStep = -1
    private func noteProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(fraction)
        let step = Int(fraction * 10)
        if step != lastLoggedStep { lastLoggedStep = step; Log.info("parakeet", "Model download \(step * 10)%") }
    }

    /// Reads one audio file and returns its sentences. Throws if Parakeet is not ready.
    func transcribe(file url: URL) async throws -> [Utterance] {
        guard let manager else { throw ParakeetError.notReady }
        let layers = await manager.decoderLayerCount
        var decoder = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(url, decoderState: &decoder)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [Utterance(start: 0, end: result.duration, text: text)]
        }
        let tokens = timings.map { TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime) }
        return TranscriptBuilder.utterances(from: tokens)
    }

    /// Transcribes both tracks of a call folder and writes transcript.txt. The live transcript is kept as transcript-live.txt.
    /// Returns true when a new transcript was written.
    func transcribeCall(folder: URL, youName: String = "You") async -> Bool {
        let fm = FileManager.default
        let mic = folder.appendingPathComponent("mic.m4a")
        let system = folder.appendingPathComponent("system.m4a")
        guard fm.fileExists(atPath: mic.path) || fm.fileExists(atPath: system.path) else { return false }
        guard await prepare() else { return false }
        lastTracks = nil

        let started = Date()
        do {
            var you: [Utterance] = []
            var them: [Utterance] = []
            // A track that is empty or broken (for example a mic file that never got any sound) is skipped,
            // so the other track still gets transcribed instead of the whole call falling back to the live text.
            if AudioFiles.isUsable(mic) {
                do { you = try await transcribe(file: mic) }
                catch { Log.warn("parakeet", "Could not read mic.m4a (\(error.localizedDescription)); using the call audio only") }
            } else if fm.fileExists(atPath: mic.path) {
                Log.warn("parakeet", "mic.m4a in \(folder.lastPathComponent) holds no usable sound; using the call audio only")
            }
            if AudioFiles.isUsable(system) {
                do { them = try await transcribe(file: system) }
                catch { Log.warn("parakeet", "Could not read system.m4a (\(error.localizedDescription))") }
            }
            if you.isEmpty && them.isEmpty && !AudioFiles.isUsable(mic) && !AudioFiles.isUsable(system) {
                Log.warn("parakeet", "No usable audio in \(folder.lastPathComponent); keeping the live transcript")
                return false
            }
            you = TranscriptBuilder.removeEchoes(you: you, them: them)
            let text = TranscriptBuilder.merge(you: you, them: them, youName: youName)
            guard text.count > 20 else {
                Log.warn("parakeet", "Parakeet heard almost nothing in \(folder.lastPathComponent); keeping the live transcript")
                return false
            }
            let live = folder.appendingPathComponent("transcript.txt")
            let liveCopy = folder.appendingPathComponent("transcript-live.txt")
            if fm.fileExists(atPath: live.path), !fm.fileExists(atPath: liveCopy.path) { try? fm.copyItem(at: live, to: liveCopy) }
            try text.write(to: live, atomically: true, encoding: .utf8)
            // Anything made from the old text is out of date.
            try? fm.removeItem(at: folder.appendingPathComponent("transcript-raw.txt"))
            try? fm.removeItem(at: folder.appendingPathComponent("transcript-clean.txt"))
            lastTracks = (you, them)
            let seconds = Date().timeIntervalSince(started)
            Log.info("parakeet", "Transcribed \(folder.lastPathComponent): \(you.count) lines from you, \(them.count) from them, in \(String(format: "%.0f", seconds)) s")
            return true
        } catch {
            Log.error("parakeet", "Transcription failed for \(folder.lastPathComponent): \(error.localizedDescription). Keeping the live transcript.")
            return false
        }
    }
}

enum ParakeetError: LocalizedError {
    case notReady
    var errorDescription: String? { "Parakeet is not ready yet." }
}

enum AudioFiles {
    /// True when the file exists and holds at least one second of sound.
    static func isUsable(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 2_000, let file = try? AVAudioFile(forReading: url) else { return false }
        return file.fileFormat.sampleRate > 0 && Double(file.length) / file.fileFormat.sampleRate >= 1.0
    }
}
