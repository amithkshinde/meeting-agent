import AVFoundation

/// Plays a call without the echo. The saved video holds your microphone, and when you use speakers the
/// microphone also picked up the call, so the video's own sound has the other people twice.
/// This plays the picture from screen.mp4, the call from system.m4a, and your microphone only while
/// the other people are quiet.
enum CleanPlayback {
    static func item(folder: URL) async -> AVPlayerItem? {
        let videoURL = folder.appendingPathComponent("screen.mp4")
        let systemURL = folder.appendingPathComponent("system.m4a")
        let micURL = folder.appendingPathComponent("mic.m4a")
        let fm = FileManager.default
        guard fm.fileExists(atPath: videoURL.path), fm.fileExists(atPath: systemURL.path) else { return nil }
        do {
            let composition = AVMutableComposition()
            let videoAsset = AVURLAsset(url: videoURL)
            let duration = try await videoAsset.load(.duration)
            guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
            videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

            func addAudio(_ url: URL) async throws -> AVMutableCompositionTrack? {
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                      let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { return nil }
                let length = try await asset.load(.duration)
                let usable = CMTimeMinimum(length, duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: usable), of: source, at: .zero)
                return track
            }

            guard try await addAudio(systemURL) != nil else { return nil }
            let item = AVPlayerItem(asset: composition)
            if fm.fileExists(atPath: micURL.path), let micTrack = try await addAudio(micURL) {
                let system = levels(of: systemURL)
                let params = AVMutableAudioMixInputParameters(track: micTrack)
                apply(duckingFor: system, to: params)
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                item.audioMix = mix
            }
            return item
        } catch {
            Log.warn("playback", "clean playback not available: \(error.localizedDescription)")
            return nil
        }
    }

    /// Mic volume: low while the call is loud, full otherwise. Short gaps count as "still talking".
    private static let window = 0.25
    private static func apply(duckingFor system: [Float], to params: AVMutableAudioMixInputParameters) {
        guard !system.isEmpty else { return }
        var active = system.map { $0 > 0.004 }
        let hold = 2 // windows (0.5 s) of quiet before the mic comes back
        var quiet = hold
        for i in active.indices {
            if active[i] { quiet = 0 } else { quiet += 1; if quiet <= hold { active[i] = true } }
        }
        let loud: Float = 0.08
        var current: Float = 1
        params.setVolume(1, at: .zero)
        for i in active.indices {
            let target: Float = active[i] ? loud : 1
            if target != current {
                let start = CMTime(seconds: Double(i) * window, preferredTimescale: 600)
                params.setVolumeRamp(fromStartVolume: current, toEndVolume: target,
                                     timeRange: CMTimeRange(start: start, duration: CMTime(seconds: 0.1, preferredTimescale: 600)))
                current = target
            }
        }
    }

    /// Loudness (RMS) of a recording, one number per quarter second.
    static func levels(of url: URL) -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: 16000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perWindow = Int(16000 * window)
        var result: [Float] = []
        var sum = 0.0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &samples)
            for sample in samples {
                let value = Double(sample) / 32768
                sum += value * value
                count += 1
                if count == perWindow {
                    result.append(Float((sum / Double(count)).squareRoot()))
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { result.append(Float((sum / Double(count)).squareRoot())) }
        return result
    }
}
