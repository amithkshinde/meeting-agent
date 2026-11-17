import Foundation

// MARK: - Voice recognition logic
//
// Everything here is plain Foundation, so it can be tested without a speech model.
// The speech tools only supply two things: who spoke when (segments) and a voice fingerprint
// (a list of numbers) for each stretch of speech. This file does the rest: it merges fragments
// of the same voice, matches voices to remembered people, uses the names seen on the call
// screen as evidence, decides what is certain and what to ask about, and writes the transcript.

/// The numbers that decide when a voice counts as a match. Voice fingerprints from compressed call
/// audio vary from call to call, so these are deliberately careful: when unsure, the app asks.
enum VoiceRules {
    /// Same voice at or above this similarity (1.0 is identical, about 0.5 is a different person).
    static let sure = 0.70
    /// The best match must beat the runner-up by at least this much.
    static let margin = 0.08
    /// Below this a voice is treated as someone new.
    static let maybe = 0.50
    /// A voice-only match teaches the library only when it is at least this strong.
    static let learnScore = 0.75
    /// Two clusters from one call at or above this are the same person split in two.
    static let mergeClusters = 0.78

    /// Screen evidence: samples where the call screen showed this person speaking.
    static let minVotes = 3
    static let strongVotes = 5
    static let minShare = 0.6

    /// Quiet voices are not worth a question.
    static let minSecondsToAsk = 15.0
}

// MARK: - Vector helpers

enum VoiceMath {
    static func normalized(_ v: [Float]) -> [Float] {
        let length = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard length > 0 else { return v }
        return v.map { $0 / length }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// Weighted average of fingerprints, scaled to length 1.
    static func blend(_ items: [(vector: [Float], weight: Double)]) -> [Float] {
        guard let first = items.first, !first.vector.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: first.vector.count)
        for item in items where item.vector.count == sum.count {
            let unit = normalized(item.vector)
            let w = Float(max(item.weight, 0.0001))
            for i in 0..<sum.count { sum[i] += unit[i] * w }
        }
        return normalized(sum)
    }
}

enum VoiceNames {
    /// "Uma" and "Uma Rao" are the same person; so are different capitals.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(separator: " ").map(String.init)
        let y = b.lowercased().split(separator: " ").map(String.init)
        guard !x.isEmpty, !y.isEmpty else { return false }
        let shorter = x.count <= y.count ? x : y
        let longer = x.count <= y.count ? y : x
        return shorter.allSatisfy { longer.contains($0) }
    }
}

// MARK: - Who spoke when

struct VoiceSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var cluster: String
    var seconds: Double { max(0, end - start) }
}

struct VoiceCluster: Codable, Equatable, Identifiable {
    var id: String               // "S1", "S2", in order of first speaking
    var embedding: [Float]       // length 1
    var seconds: Double
}

/// One stretch of speech as the diarizer reports it.
struct RawVoiceSegment: Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var embedding: [Float]
}

enum VoiceClustering {
    /// Joins the diarizer's speakers when their voices are almost identical (the diarizer sometimes
    /// splits one person in two), and renames them S1, S2 … in the order they first speak.
    static func build(from raw: [RawVoiceSegment], mergeAbove: Double = VoiceRules.mergeClusters) -> (clusters: [VoiceCluster], segments: [VoiceSegment]) {
        let sorted = raw.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return ([], []) }

        struct Group { var ids: Set<String>; var vector: [Float]; var seconds: Double; var first: Double }
        var groups: [Group] = []
        var byId: [String: Int] = [:]
        for speaker in Set(sorted.map { $0.speaker }) {
            let own = sorted.filter { $0.speaker == speaker }
            let vector = VoiceMath.blend(own.map { ($0.embedding, $0.end - $0.start) })
            groups.append(Group(ids: [speaker], vector: vector, seconds: own.reduce(0) { $0 + ($1.end - $1.start) }, first: own.map { $0.start }.min() ?? 0))
        }
        // Merge the closest pair until none is close enough.
        while groups.count > 1 {
            var best: (Int, Int, Double)?
            for i in 0..<groups.count {
                for j in (i + 1)..<groups.count {
                    let score = VoiceMath.cosine(groups[i].vector, groups[j].vector)
                    if score >= mergeAbove, best == nil || score > best!.2 { best = (i, j, score) }
                }
            }
            guard let (i, j, _) = best else { break }
            var merged = groups[i]
            merged.ids.formUnion(groups[j].ids)
            merged.vector = VoiceMath.blend([(groups[i].vector, groups[i].seconds), (groups[j].vector, groups[j].seconds)])
            merged.seconds += groups[j].seconds
            merged.first = min(groups[i].first, groups[j].first)
            groups.remove(at: j)
            groups[i] = merged
        }
        groups.sort { $0.first < $1.first }
        for (index, group) in groups.enumerated() { for id in group.ids { byId[id] = index } }

        let clusters = groups.enumerated().map { VoiceCluster(id: "S\($0.offset + 1)", embedding: $0.element.vector, seconds: $0.element.seconds) }
        let segments = sorted.map { VoiceSegment(start: $0.start, end: $0.end, cluster: "S\((byId[$0.speaker] ?? 0) + 1)") }
        return (clusters, segments)
    }
}

// MARK: - Remembered voices

struct VoiceProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var model: String             // fingerprints from different speech models cannot be compared
    var centroid: [Float]
    var seconds: Double           // how much of their speech this is built from
    var calls: Int
    var updatedAt: Date
}

struct VoiceMatch: Equatable {
    var name: String
    var id: String
    var score: Double
    var runnerUp: Double          // the next best score from a different person, 0 if there is none

    var isSure: Bool { score >= VoiceRules.sure && score - runnerUp >= VoiceRules.margin }
    var isMaybe: Bool { score >= VoiceRules.maybe }
}

final class VoiceLibrary {
    let url: URL
    private(set) var profiles: [VoiceProfile]
    private let queue = DispatchQueue(label: "meetingagent.voices")

    init(url: URL) {
        self.url = url
        self.profiles = Self.read(url)
    }

    private static func read(_ url: URL) -> [VoiceProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([VoiceProfile].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: url, options: .atomic)
            // Voice fingerprints are personal: readable by this account only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func match(_ embedding: [Float], model: String) -> VoiceMatch? {
        queue.sync {
            let scored = profiles.filter { $0.model == model && $0.centroid.count == embedding.count }
                .map { ($0, VoiceMath.cosine($0.centroid, embedding)) }
                .sorted { $0.1 > $1.1 }
            guard let top = scored.first else { return nil }
            return VoiceMatch(name: top.0.name, id: top.0.id, score: top.1, runnerUp: scored.dropFirst().first?.1 ?? 0)
        }
    }

    /// Adds to a person's voice, or remembers a new person.
    func learn(name: String, embedding: [Float], seconds: Double, model: String, at date: Date = Date()) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !embedding.isEmpty, seconds > 0 else { return }
        queue.sync {
            if let index = profiles.firstIndex(where: { $0.model == model && VoiceNames.same($0.name, clean) }) {
                var profile = profiles[index]
                // Older speech counts for less once there is plenty of it, so the profile can follow a voice over time.
                profile.centroid = VoiceMath.blend([(profile.centroid, min(profile.seconds, 300)), (embedding, min(seconds, 120))])
                profile.seconds += seconds
                profile.calls += 1
                profile.updatedAt = date
                if clean.count > profile.name.count { profile.name = clean }
                profiles[index] = profile
            } else {
                profiles.append(VoiceProfile(id: UUID().uuidString, name: clean, model: model, centroid: VoiceMath.normalized(embedding), seconds: seconds, calls: 1, updatedAt: date))
            }
            persist()
        }
    }

    func rename(id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        queue.sync {
            if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index].name = clean; persist() }
        }
    }

    func remove(id: String) {
        queue.sync { profiles.removeAll { $0.id == id }; persist() }
    }

    func removeAll() {
        queue.sync { profiles = []; persist() }
    }
}

// MARK: - Names seen on the call screen

enum ScreenEvidence {
    /// How many times the call screen showed each person speaking while each voice was talking.
    /// `samples` are (seconds into the call, name shown as speaking). The highlight on a call screen lags a little,
    /// so a sample counts if it falls within a short margin of a stretch of speech. A sample that fits two
    /// different voices is ignored, because it proves nothing.
    static func votes(segments: [VoiceSegment], samples: [(t: Double, name: String)], exclude: [String] = []) -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        let sorted = segments.sorted { $0.start < $1.start }
        for sample in samples where !exclude.contains(where: { VoiceNames.same($0, sample.name) }) {
            let hits = Set(sorted.filter { sample.t >= $0.start - 0.5 && sample.t <= $0.end + 0.5 }.map { $0.cluster })
            guard hits.count == 1, let cluster = hits.first else { continue }
            result[cluster, default: [:]][sample.name, default: 0] += 1
        }
        return result
    }
}

// MARK: - Deciding who is who

enum VoiceStatus: String, Codable { case named, ask, unknown }

struct VoiceDecision: Codable, Equatable, Identifiable {
    var id: String                 // the cluster id
    var name: String?
    var status: VoiceStatus
    var why: String                // plain words, for the log and the review card
    var suggestion: String? = nil  // shown as the first choice when asking
    var voiceName: String? = nil
    var voiceScore: Double? = nil
    var screenName: String? = nil
    var screenVotes: Int = 0
    var seconds: Double = 0
    var learn: Bool = false        // teach the library this voice now
    var quote: String? = nil       // something they said, so the person can recognise the voice
}

enum VoiceResolver {
    static func resolve(clusters: [VoiceCluster], votes: [String: [String: Int]], library: VoiceLibrary, model: String, attendees: [String] = [], exclude: [String] = []) -> [VoiceDecision] {
        var out: [VoiceDecision] = []

        for cluster in clusters {
            var d = VoiceDecision(id: cluster.id, name: nil, status: .unknown, why: "", seconds: cluster.seconds)

            // Evidence from the call screen.
            let tally = votes[cluster.id] ?? [:]
            let total = tally.values.reduce(0, +)
            var screen: (name: String, votes: Int)?
            if let top = tally.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
               top.value >= VoiceRules.minVotes, Double(top.value) >= Double(total) * VoiceRules.minShare {
                screen = (top.key, top.value)
                d.screenName = top.key
                d.screenVotes = top.value
            }

            // Evidence from the voice itself.
            let match = library.match(cluster.embedding, model: model)
            if let match, !exclude.contains(where: { VoiceNames.same($0, match.name) }) {
                d.voiceName = match.name
                d.voiceScore = (match.score * 100).rounded() / 100
            }
            let voiceSure = d.voiceName != nil && (match?.isSure ?? false)
            let voiceMaybe = d.voiceName != nil && (match?.isMaybe ?? false)

            if let screen {
                if voiceSure, let voice = d.voiceName {
                    if VoiceNames.same(screen.name, voice) {
                        d.name = screen.name.count >= voice.count ? screen.name : voice
                        d.status = .named; d.learn = true
                        d.why = "the call screen and the voice agree"
                    } else {
                        d.status = .ask; d.suggestion = screen.name
                        d.why = "the call screen says \(screen.name) but the voice sounds like \(voice)"
                    }
                } else if screen.votes >= VoiceRules.strongVotes {
                    d.name = screen.name; d.status = .named; d.learn = true
                    d.why = "the call screen showed \(screen.name) speaking"
                } else {
                    d.status = .ask; d.suggestion = screen.name
                    d.why = "the call screen showed \(screen.name) speaking, but only a few times"
                }
            } else if voiceSure, let voice = d.voiceName {
                d.name = voice; d.status = .named
                d.learn = (match?.score ?? 0) >= VoiceRules.learnScore
                d.why = "the voice matches \(voice)"
            } else if voiceMaybe, let voice = d.voiceName {
                d.status = .ask; d.suggestion = voice
                d.why = "the voice is a bit like \(voice)"
            } else if cluster.seconds >= VoiceRules.minSecondsToAsk {
                d.status = .ask
                d.why = "a new voice"
            } else {
                d.why = "too little speech to tell"
            }
            out.append(d)
        }

        // One person left over and one name left over: offer that name.
        let used = out.compactMap { $0.name } + out.compactMap { $0.suggestion }
        let spare = attendees.filter { person in
            !exclude.contains(where: { VoiceNames.same($0, person) }) && !used.contains(where: { VoiceNames.same($0, person) })
        }
        let open = out.indices.filter { out[$0].status == .ask && out[$0].suggestion == nil }
        if spare.count == 1, open.count == 1 {
            out[open[0]].suggestion = spare[0]
            out[open[0]].why += ", and \(spare[0]) is the only invited person not yet placed"
        }
        return out
    }

    /// The label each voice gets in the transcript.
    static func labels(for decisions: [VoiceDecision], clusters: [VoiceCluster], onlyOneFallback: String = "Them") -> [String: String] {
        var labels: [String: String] = [:]
        let unnamed = decisions.filter { $0.name == nil }
        for d in decisions {
            if let name = d.name { labels[d.id] = name; continue }
            if decisions.count == 1 { labels[d.id] = onlyOneFallback; continue }
            let number = (unnamed.firstIndex(where: { $0.id == d.id }) ?? 0) + 1
            labels[d.id] = "Speaker \(number)"
        }
        return labels
    }
}

// MARK: - The transcript

/// One sentence with the voice that said it. `cluster` is nil for the user's own microphone ("You").
struct Turn: Codable, Equatable {
    var cluster: String?
    var start: Double
    var end: Double
    var text: String
}

enum VoiceTranscript {
    /// Finds the voice that was talking during a sentence: the one with the most overlap, or the nearest one
    /// within a second and a half.
    static func cluster(for start: Double, end: Double, in segments: [VoiceSegment]) -> String? {
        var overlap: [String: Double] = [:]
        for s in segments {
            let shared = min(end, s.end) - max(start, s.start)
            if shared > 0 { overlap[s.cluster, default: 0] += shared }
        }
        if let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) { return best.key }
        let middle = (start + end) / 2
        let nearest = segments.min { abs(($0.start + $0.end) / 2 - middle) < abs(($1.start + $1.end) / 2 - middle) }
        if let nearest, min(abs(nearest.start - end), abs(nearest.end - start)) <= 1.5 { return nearest.cluster }
        return nil
    }

    static func turns(you: [Utterance], them: [Utterance], segments: [VoiceSegment]) -> [Turn] {
        var out = you.map { Turn(cluster: nil, start: $0.start, end: $0.end, text: $0.text) }
        var previous: String?
        for u in them.sorted(by: { $0.start < $1.start }) {
            let c = cluster(for: u.start, end: u.end, in: segments) ?? previous
            previous = c ?? previous
            out.append(Turn(cluster: c ?? "?", start: u.start, end: u.end, text: u.text))
        }
        return out
    }

    /// Lines like "[mm:ss] Uma: text", stamped at the end of the sentence as before.
    static func render(_ turns: [Turn], labels: [String: String], youName: String = "You", themName: String = "Them") -> String {
        let rows = turns.sorted { $0.end == $1.end ? ($0.cluster == nil && $1.cluster != nil) : $0.end < $1.end }
        let lines = rows.map { turn -> String in
            let who = turn.cluster.map { labels[$0] ?? themName } ?? youName
            return "\(TranscriptBuilder.stamp(turn.end)) \(who): \(turn.text)"
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// A short line someone said, to help the person recognise a voice.
    static func quote(for cluster: String, in turns: [Turn]) -> String? {
        let own = turns.filter { $0.cluster == cluster && $0.text.split(separator: " ").count >= 6 }
        guard let pick = own.max(by: { $0.text.count < $1.text.count }) ?? turns.first(where: { $0.cluster == cluster }) else { return nil }
        let words = pick.text.split(separator: " ")
        return words.count > 18 ? words.prefix(18).joined(separator: " ") + "…" : pick.text
    }
}

// MARK: - What is kept with each call

/// Saved as voices.json in the call's folder. It holds what is needed to ask "who is this?" later
/// and to teach the library once the person answers.
struct VoiceReview: Codable, Equatable {
    var model: String
    var clusters: [VoiceCluster]
    var decisions: [VoiceDecision]
    var createdAt: Date = Date()

    var pending: [VoiceDecision] { decisions.filter { $0.status == .ask } }

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("voices.json") }
    static func turnsURL(_ folder: URL) -> URL { folder.appendingPathComponent("turns.json") }

    static func load(_ folder: URL) -> VoiceReview? {
        guard let data = try? Data(contentsOf: url(folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceReview.self, from: data)
    }

    func save(to folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: Self.url(folder), options: .atomic) }
    }

    /// The person answered. A name teaches the library; an empty answer leaves the voice as it was.
    mutating func answer(cluster id: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = decisions.firstIndex(where: { $0.id == id }), !clean.isEmpty else { return }
        decisions[index].name = clean
        decisions[index].status = .named
        decisions[index].learn = true
        decisions[index].why = "you told me"
    }
}

enum VoiceTurns {
    static func load(_ folder: URL) -> [Turn] {
        guard let data = try? Data(contentsOf: VoiceReview.turnsURL(folder)) else { return [] }
        return (try? JSONDecoder().decode([Turn].self, from: data)) ?? []
    }

    static func save(_ turns: [Turn], to folder: URL) {
        if let data = try? JSONEncoder().encode(turns) { try? data.write(to: VoiceReview.turnsURL(folder), options: .atomic) }
    }
}
