import Foundation

/// Everything that happens after a call ends: clean the transcript, write the summary,
/// pull out promises, and refresh the project brief.
final class CallProcessor {
    private let memory: MemoryStore
    private let knowledge: KnowledgeStore
    private let projects: ProjectStore
    private let commitments: CommitmentStore
    private let agent: AgentModel
    weak var library: LibraryModel?

    init(memory: MemoryStore, knowledge: KnowledgeStore, projects: ProjectStore, commitments: CommitmentStore, agent: AgentModel) {
        self.memory = memory
        self.knowledge = knowledge
        self.projects = projects
        self.commitments = commitments
        self.agent = agent
    }

    // MARK: - Prompts

    static let summarySystem = """
    You write the minutes of meeting (MOM) for the user after a call. "You" is the user and "Them" is everyone else. \
    The transcript is automatic speech recognition, so names and numbers may be wrong. Mark anything unclear instead of guessing. \
    If you are given a list of the people on the call, use their names where the transcript makes clear who said what. \
    A line may begin with a real person's name instead of "Them", when the voice or the video showed who was speaking. Use those names. \
    Lines that begin with "Speaker 1", "Speaker 2" and so on are different people whose names are not known: keep them apart and never guess their names. \
    Write in English, in Markdown, with exactly these six headings and nothing else, each written exactly as shown: \
    ## Summary, ## Discussion, ## Decisions, ## Action items, ## Open questions, ## Raise next time. \
    Summary is three sentences at most, saying what the meeting was for and how it ended. \
    Discussion is short bullets grouped by topic, each saying who raised or decided what. \
    Action items are one bullet each, written as the person's actual name, a colon, the task, and the due date if one was mentioned. Never write the word "Owner". If nobody was named for a task, write "Not assigned:". \
    Do not copy these instructions into the headings. \
    Write "None." for an empty section. Only use what the transcript says. Do not write the date or the attendee list, they are added for you.
    """

    /// The distinct speakers named in a transcript, for the MOM header.
    static func attendees(in transcript: String, you: String) -> [String] {
        var seen: [String] = []
        for line in transcript.components(separatedBy: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let label = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count < 40, label != "You", label != "Them", !seen.contains(label) else { continue }
            seen.append(label)
        }
        let me = you.trimmingCharacters(in: .whitespaces)
        return [me.isEmpty ? "You" : "\(me) (You)"] + seen.filter { !VoiceNames.same($0, me) }
    }

    /// Added to the summary prompt when the call shared several screens (a design review).
    static let byScreenNote = """
     The call shared several screens. Lines like "--- Screen 2 shown at 12:30 ---" mark when each one appeared. \
    After the other sections, add "## By screen" with a "### Screen N" heading for each screen that was discussed, \
    listing the feedback, questions and decisions about that screen as short bullets. Skip screens nobody discussed.
    """

    static var cleanSystem: String {
        """
    You fix the output of automatic speech recognition for a call transcript. Each line looks like "[mm:ss] You: text" or "[mm:ss] Them: text". \
    The speech is mostly English, and sometimes another European language. \
    Fix obvious recognition mistakes, the spelling of names and numbers, punctuation and capital letters, using the other lines and the names of the people on the call for context. \
    Keep every line, in the same order, with the same timestamp. Do not summarise, translate, add or remove sentences, and do not guess: if you are unsure, leave the words as they are. \
    Each line starts with a speaker label: "You", "Them", "Speaker 1", "Speaker 2" or a person's name. Keep every label exactly as written. \
    If exactly one other person was on the call, you may write their name instead of "Them". \
    Reply with the corrected lines only, nothing before or after.
    """
    }

    static let commitmentsSystem = """
    You find promises in a call transcript. "You" is the user and "Them" is everyone else. \
    Reply with JSON only, in exactly this shape: {"items": [{"owner": "You", "text": "...", "due": "2026-10-24"}]}. \
    Include only things someone clearly promised or agreed to do. "owner" is "You" for the user, otherwise the person's name if it is known, otherwise "Them". \
    "text" is under 20 words and says what will be done. "due" is a date as YYYY-MM-DD worked out from the call date (for example "by Friday"), or an empty string if no date was given. \
    At most 12 items. Never invent anything. If there are no promises, return {"items": []}.
    """

    /// The user's own name as the call app would show it, so their tile is never mistaken for someone else.
    static var userName: String {
        let saved = (UserDefaults.standard.string(forKey: "userDisplayName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? NSFullUserName() : saved
    }

    /// Puts real names on "Them" lines using who the video showed speaking. The first time it keeps the
    /// original as transcript-raw.txt, and it always works from that original, so it is safe to run again.
    @discardableResult
    static func attributeSpeakers(folder: URL) -> SpeakerAttribution.Result? {
        let samples = SpeakerLog.load(folder)
        guard !samples.isEmpty else { return nil }
        let rawURL = folder.appendingPathComponent("transcript-raw.txt")
        let liveURL = folder.appendingPathComponent("transcript.txt")
        if !FileManager.default.fileExists(atPath: rawURL.path) {
            try? FileManager.default.copyItem(at: liveURL, to: rawURL)
        }
        guard let source = try? String(contentsOf: rawURL, encoding: .utf8) else { return nil }
        let result = SpeakerAttribution.apply(to: source, samples: samples, exclude: [userName])
        guard result.named > 0 else { return result }
        try? result.text.write(to: liveURL, atomically: true, encoding: .utf8)
        // Anything cleaned from the old text is out of date now.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("transcript-clean.txt"))
        Log.write("speakers: named \(result.named) of \(result.total) lines (\(result.names.joined(separator: ", ")))")
        return result
    }

    // MARK: - The pipeline

    /// Runs after a call. `wait` gives the speech engine a moment to finish the last sentence.
    func process(folder: URL, wait: Bool) {
        let id = folder.lastPathComponent
        guard let first = memory.records.first(where: { $0.id == id }) else { return }
        agent.summarizing = true

        Task { @MainActor in
            defer { self.agent.summarizing = false }
            if wait { try? await Task.sleep(nanoseconds: 4_000_000_000) }

            var transcribed = false
            // 0. Parakeet listens to the two audio tracks and writes the transcript. If it can't, the live transcript stays.
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.m4a").path)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.m4a").path) {
                let firstTime = !ParakeetEngine.shared.isReady
                self.agent.raise(AppAlert(id: "transcribing", message: firstTime
                    ? "Transcribing with Parakeet. The first time it downloads the speech model (about 480 MB), so this can take a few minutes."
                    : "Transcribing this call with Parakeet…", isInfo: true))
                let done = await ParakeetEngine.shared.transcribeCall(folder: folder, youName: "You")
                transcribed = done
                self.agent.clearAlert("transcribing")
                if !done, case .failed(let why) = ParakeetEngine.shared.state {
                    self.agent.raise(AppAlert(id: "parakeet-failed", message: "Parakeet isn't available (\(why)), so this call uses the live transcript. It will try again on the next call.", button: "Details", section: LibraryModel.settingsKey, isInfo: true))
                }
            }

            // Read the names off the call video, so the voices can be matched to the people shown speaking.
            await self.readNamesFromVideo(folder: folder)

            // Voices: tell the people apart by how they sound, and use the names seen on the call screen.
            var namedByVoice = false
            if transcribed, Voices.isOn, let tracks = ParakeetEngine.shared.lastTracks {
                namedByVoice = await self.identifyVoices(folder: folder, tracks: tracks, record: first)
            }
            if !namedByVoice { CallProcessor.attributeSpeakers(folder: folder) }
            let raw = (try? String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
            guard raw.count > 60 else {
                Log.write("summary skipped: the transcript is too short")
                return
            }
            guard let key = AIAccess.key(project: first.client, projects: self.projects) else {
                Log.write("summary skipped: no AI available")
                return
            }

            // 1. Clean up the transcript (helps most with Hindi and mixed Hindi-English).
            var transcript = raw
            do {
                if let cleaned = try await self.clean(raw, key: key, people: (first.attendees ?? []).map { $0.name }) {
                    transcript = cleaned
                    try? cleaned.write(to: folder.appendingPathComponent("transcript-clean.txt"), atomically: true, encoding: .utf8)
                    Log.write("transcript cleaned")
                }
            } catch ChatError.badKey {
                self.keyRejected()
                return
            } catch {
                Log.write("transcript clean-up skipped: \(error.localizedDescription)")
            }

            // 2. Summary.
            let current = self.memory.records.first(where: { $0.id == id }) ?? first
            let client = current.client
            let earlier = self.memory.context(client: client, excluding: id)
            let people = (current.attendees ?? []).map { $0.name }
            let saved = (UserDefaults.standard.string(forKey: "userDisplayName") ?? "").trimmed
            let selfLine = saved.isEmpty ? "" : "The user (\"You\") is named \(saved).\n"
            let peopleLine = selfLine + (people.isEmpty ? "" : "People on the call besides the user: \(people.joined(separator: ", ")).\n") + (selfLine.isEmpty && people.isEmpty ? "" : "\n")
            let screens = ScreenIndex.load(folder)
            let marked = screens.count >= 2 ? ScreenIndex.annotate(transcript, screens: screens) : transcript
            let prompt = (earlier.isEmpty ? "" : "Earlier calls with this client:\n\(earlier)\n\n")
                + peopleLine
                + "Transcript of this call:\n\(String(marked.suffix(60_000)))\n\nWrite the notes now."
            do {
                let system = CallProcessor.summarySystem + (screens.count >= 2 ? CallProcessor.byScreenNote : "")
                let summary = try await ChatService.complete(key: key, system: system, prompt: prompt, maxTokens: screens.count >= 2 ? 2000 : 1500)
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let who = CallProcessor.attendees(in: transcript, you: saved.isEmpty ? NSFullUserName() : saved).joined(separator: ", ")
                let header = "# Minutes of meeting\n\n- Project: \(client)\n- App: \(current.app)\n- Date: \(formatter.string(from: current.date))\n- Attendees: \(who)\n\n"
                let url = folder.appendingPathComponent("summary.md")
                try (header + summary).write(to: url, atomically: true, encoding: .utf8)
                var updated = self.memory.records.first(where: { $0.id == id }) ?? current
                updated.summary = summary
                self.memory.upsert(updated)
                self.agent.lastSummaryURL = url
                self.agent.clearAlert("summary")
                Log.write("summary saved: \(url.path)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                    if self?.agent.lastSummaryURL == url { self?.agent.lastSummaryURL = nil }
                }
            } catch ChatError.badKey {
                self.keyRejected()
                return
            } catch {
                Log.write("summary failed: \(error.localizedDescription)")
                self.agent.raise(AppAlert(id: "summary", message: "I couldn't write the call summary: \(error.localizedDescription)", button: "Open app"))
                return
            }

            // 3. Promises.
            let latest = self.memory.records.first(where: { $0.id == id }) ?? current
            if let found = await self.promises(in: transcript, record: latest, key: key) {
                self.commitments.replace(callId: id, with: found)
            }

            // 4. Refresh the project brief and the lists.
            if latest.client != MemoryStore.unassigned { self.library?.generateBrief(for: latest.client, quiet: true) }
            self.library?.reload()
        }
    }

    // MARK: - Who is speaking

    /// Looks through the saved call video for the highlighted speaker's name, unless that was already done.
    @MainActor
    private func readNamesFromVideo(folder: URL) async {
        let video = folder.appendingPathComponent("screen.mp4")
        guard UserDefaults.standard.object(forKey: "watchSpeakers") as? Bool ?? true,
              FileManager.default.fileExists(atPath: video.path),
              SpeakerLog.load(folder).isEmpty else { return }
        agent.raise(AppAlert(id: "reading-video", message: "Reading the names from the call video…", isInfo: true))
        defer { agent.clearAlert("reading-video") }
        let started = Date()
        let result = await CallWatcher().analyseVideo(at: video, folder: folder) { _ in }
        Log.info("watcher", "\(folder.lastPathComponent): read the video in \(String(format: "%.0f", Date().timeIntervalSince(started))) s, \(result.speakerSamples) speaker readings, \(result.screens) screens")
    }

    /// How many different people (other than the user) the call screen showed speaking for a few seconds.
    private static func screenPeople(_ samples: [(t: Double, name: String)], exclude: [String]) -> Int {
        var seconds: [String: Int] = [:]
        for sample in samples where !exclude.contains(where: { VoiceNames.same($0, sample.name) }) { seconds[sample.name, default: 0] += 1 }
        let names = seconds.filter { $0.value >= 4 }.map { $0.key }
        // "Ananya Kan…" and "Ananya Kannan" are one person.
        let distinct = names.filter { short in
            guard short.hasSuffix("…") else { return true }
            let stem = String(short.dropLast())
            return !names.contains { $0 != short && $0.hasPrefix(stem) }
        }
        return distinct.count
    }

    /// Splits the other side of the call into voices, names the ones it is sure about, and writes a transcript
    /// with those names. Voices it is unsure about are kept for the person to name. Returns true when the
    /// transcript was rewritten.
    @MainActor
    private func identifyVoices(folder: URL, tracks: (you: [Utterance], them: [Utterance]), record: CallRecord) async -> Bool {
        let fm = FileManager.default
        // If the call audio was blank (the other people were never recorded on it) but the microphone heard
        // everyone, tell the voices apart on the microphone recording instead.
        let seconds: ([Utterance]) -> Double = { $0.reduce(0) { $0 + max(0, $1.end - $1.start) } }
        let youSeconds = seconds(tracks.you)
        let themSeconds = seconds(tracks.them)
        let micFile = folder.appendingPathComponent("mic.m4a")
        let useMic = youSeconds > 120 && themSeconds < youSeconds * 0.15 && fm.fileExists(atPath: micFile.path)
        let source = useMic ? micFile : folder.appendingPathComponent("system.m4a")
        guard fm.fileExists(atPath: source.path), useMic ? !tracks.you.isEmpty : !tracks.them.isEmpty else { return false }
        guard Voices.beginAttempt() else { return false }
        defer { Voices.endAttempt() }

        agent.raise(AppAlert(id: "voices-working", message: "Working out who is speaking…", isInfo: true))
        defer { agent.clearAlert("voices-working") }

        let started = Date()
        let raw: [RawVoiceSegment]
        do {
            raw = try await VoiceEngine.diarize(file: source)
        } catch {
            Log.error("voices", "Could not tell the voices apart: \(error.localizedDescription)")
            return false
        }
        var built = VoiceClustering.build(from: raw)
        guard !built.clusters.isEmpty else {
            Log.warn("voices", "No speech found to tell apart in \(folder.lastPathComponent)")
            return false
        }
        if useMic {
            // On the microphone, the user is one of the voices. If there is only one real voice, it was just a monologue.
            guard built.clusters.filter({ $0.seconds >= 15 }).count >= 2 else {
                Log.info("voices", "\(folder.lastPathComponent): the call audio was blank but the microphone has only one voice, so nothing to separate")
                return false
            }
            Log.warn("voices", "\(folder.lastPathComponent): the call audio was blank, so the voices were told apart on your microphone recording")
        }

        let me = [CallProcessor.userName]
        let samples = SpeakerLog.load(folder).map { (t: $0.t, name: $0.name) }
        // The call screen showed more people speaking than there are voices: ask the voice step to look for more.
        let expected = Self.screenPeople(samples, exclude: me) + (useMic ? 1 : 0)
        if expected > built.clusters.count, expected <= 8,
           let more = try? await VoiceEngine.diarize(file: source, minSpeakers: expected) {
            let again = VoiceClustering.build(from: more, mergeAbove: 0.9)
            if again.clusters.count > built.clusters.count {
                Log.info("voices", "\(folder.lastPathComponent): the screen showed \(expected) people but \(built.clusters.count) voices were found, so it looked again and found \(again.clusters.count)")
                built = again
            }
        }
        let attendees = (record.attendees ?? []).map { $0.name }
        let votes = ScreenEvidence.votes(segments: built.segments, samples: samples, exclude: me)
        var decisions = VoiceResolver.resolve(clusters: built.clusters, votes: votes, library: Voices.library, model: Voices.model, attendees: attendees, exclude: me)
        let turns = useMic
            ? VoiceTranscript.turns(you: [], them: tracks.you, segments: built.segments)
            : VoiceTranscript.turns(you: tracks.you, them: tracks.them, segments: built.segments)
        for index in decisions.indices { decisions[index].quote = VoiceTranscript.quote(for: decisions[index].id, in: turns) }
        if useMic, let biggest = decisions.max(by: { $0.seconds < $1.seconds }), biggest.name == nil,
           !decisions.contains(where: { $0.name.map { VoiceNames.same($0, CallProcessor.userName) } ?? false }),
           let index = decisions.firstIndex(where: { $0.id == biggest.id }) {
            decisions[index].suggestion = CallProcessor.userName
        }

        let labels = VoiceResolver.labels(for: decisions, clusters: built.clusters)
        let text = VoiceTranscript.render(turns, labels: labels)
        guard text.count > 20 else { return false }

        let transcriptURL = folder.appendingPathComponent("transcript.txt")
        let rawURL = folder.appendingPathComponent("transcript-raw.txt")
        if !fm.fileExists(atPath: rawURL.path), let original = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            try? original.write(to: rawURL, atomically: true, encoding: .utf8)
        }
        do { try text.write(to: transcriptURL, atomically: true, encoding: .utf8) } catch { return false }
        try? fm.removeItem(at: folder.appendingPathComponent("transcript-clean.txt"))

        // Teach the library the voices that were named with confidence.
        for decision in decisions where decision.learn {
            guard let name = decision.name, let cluster = built.clusters.first(where: { $0.id == decision.id }) else { continue }
            Voices.library.learn(name: name, embedding: cluster.embedding, seconds: cluster.seconds, model: Voices.model)
        }

        let review = VoiceReview(model: Voices.model, clusters: built.clusters, decisions: decisions)
        review.save(to: folder)
        VoiceTurns.save(turns, to: folder)

        let summary = decisions.map { "\($0.id)=\($0.name ?? $0.status.rawValue) (\($0.why))" }.joined(separator: "; ")
        Log.info("voices", "\(folder.lastPathComponent): \(built.clusters.count) voices in \(String(format: "%.0f", Date().timeIntervalSince(started))) s. \(summary)")

        let waiting = review.pending.count
        if waiting > 0 {
            agent.raise(AppAlert(id: "voices-\(record.id)", message: waiting == 1 ? "There's a voice in your last call I couldn't name. Who is it?" : "There are \(waiting) voices in your last call I couldn't name. Who are they?", button: "Name them", section: "§action:voices:\(record.id)"))
        }
        return true
    }

    private func keyRejected() {
        if AIAccess.localEverywhere == false { Keychain.delete() }
        agent.hasKey = false
        agent.raise(AppAlert(id: "key", message: "Your AI key was rejected, so I can't write summaries or suggestions. Paste a new one in Settings.", button: "Fix it", section: LibraryModel.settingsKey))
    }

    // MARK: - Steps (these only compute; the caller applies the results)

    /// Fixes recognition mistakes a few lines at a time. Returns nil if the transcript is too short or too long to bother.
    private func clean(_ raw: String, key: String, people: [String]) async throws -> String? {
        let lines = raw.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
        guard lines.count >= 3, raw.count <= 120_000 else { return nil }

        let limit = key == AIAccess.localKey ? 2200 : 5000
        var chunks: [[String]] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > limit, !current.isEmpty {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { chunks.append(current) }

        let peopleLine = people.isEmpty ? "" : "People on the call besides the user: \(people.joined(separator: ", ")).\n\n"
        var output: [String] = []
        for chunk in chunks {
            let prompt = peopleLine + "Transcript lines:\n" + chunk.joined(separator: "\n")
            var reply: String?
            for attempt in 0..<2 {
                do {
                    reply = try await ChatService.complete(key: key, system: CallProcessor.cleanSystem, prompt: prompt, maxTokens: 2600)
                    break
                } catch ChatError.badKey {
                    throw ChatError.badKey
                } catch {
                    // Free keys have a requests-per-minute limit. Wait a little and try once more.
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 20_000_000_000) }
                }
            }
            let fixed = (reply ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmed }
                .filter { $0.hasPrefix("[") }
            output += CallProcessor.looksRight(original: chunk, fixed: fixed) ? fixed : chunk
        }
        return output.joined(separator: "\n")
    }

    /// A safety net: if the "fixed" text lost or gained lots of lines, keep the original.
    private static func looksRight(original: [String], fixed: [String]) -> Bool {
        guard !fixed.isEmpty, !original.isEmpty else { return false }
        let lineRatio = Double(fixed.count) / Double(original.count)
        let charRatio = Double(fixed.joined().count) / Double(max(1, original.joined().count))
        return lineRatio > 0.85 && lineRatio < 1.15 && charRatio > 0.6 && charRatio < 1.6
    }

    private func promises(in transcript: String, record: CallRecord, key: String) async -> [Commitment]? {
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "EEEE, d MMMM yyyy"
        let people = (record.attendees ?? []).map { $0.name }
        let peopleLine = people.isEmpty ? "" : "People on the call besides the user: \(people.joined(separator: ", ")).\n"
        let prompt = "Call date: \(dayFormat.string(from: record.date))\n\(peopleLine)Transcript:\n\(String(transcript.suffix(40_000)))\n\nReturn the JSON now."
        do {
            let reply = try await ChatService.complete(key: key, system: CallProcessor.commitmentsSystem, prompt: prompt, json: true, maxTokens: 900)
            guard let object = CallProcessor.jsonObject(from: reply), let list = object["items"] as? [[String: Any]] else { return nil }
            let parse = DateFormatter()
            parse.dateFormat = "yyyy-MM-dd"
            return list.prefix(12).compactMap { entry -> Commitment? in
                guard let text = (entry["text"] as? String)?.trimmed, !text.isEmpty else { return nil }
                var owner = ((entry["owner"] as? String) ?? "Them").trimmed
                if owner.isEmpty { owner = "Them" }
                if ["you", "me", "i", "user"].contains(owner.lowercased()) { owner = "You" }
                let due = (entry["due"] as? String).flatMap { parse.date(from: $0.trimmed) }
                return Commitment(id: UUID().uuidString, callId: record.id, project: record.client, owner: owner, text: text, due: due, done: false, created: Date())
            }
        } catch {
            Log.write("promises not extracted: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reads an email out of whatever the AI sent back: "Subject: …" then the body, or JSON with subject and body.
    static func parseEmail(_ reply: String) -> (subject: String, body: String)? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let end = text.range(of: "```", options: .backwards) { text = String(text[..<end.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("{"), let object = jsonObject(from: text),
           let body = (object["body"] as? String)?.trimmed, !body.isEmpty {
            let subject = ((object["subject"] as? String) ?? "Following up on our call").trimmed
            return (subject.isEmpty ? "Following up on our call" : subject, body.replacingOccurrences(of: "\\n", with: "\n"))
        }
        var lines = text.components(separatedBy: "\n")
        var subject = "Following up on our call"
        if let first = lines.first, first.lowercased().hasPrefix("subject:") {
            let value = String(first.dropFirst("subject:".count)).trimmed
            if !value.isEmpty { subject = value }
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmed
        return body.count >= 20 ? (subject, body) : nil
    }

    static func jsonObject(from reply: String) -> [String: Any]? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            text = String(text[first...last])
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Follow-up email

    static let followUpSystem = """
    You write a short follow-up email from the user to the people on a call. Write like a real person: plain, warm, direct, short sentences. \
    No stock phrases such as "I hope this email finds you well" or "Please do not hesitate". Recap what was decided, list the action items with who owns each and any dates, \
    and ask about anything still open. Under 170 words. Use only what the notes say. \
    Reply in plain text in exactly this layout and nothing else: the first line is "Subject: " followed by the subject, then a blank line, then the email body.
    """

    func followUp(for call: CallRecord, key: String) async throws -> (subject: String, body: String) {
        let people = (call.attendees ?? []).map { $0.name }
        let mine = commitments.items.filter { $0.callId == call.id }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let promises = mine.map { item -> String in
            let who = item.isMine ? "You" : item.owner
            let when = item.due.map { " by \(formatter.string(from: $0))" } ?? ""
            return "- \(who): \(item.text)\(when)"
        }.joined(separator: "\n")
        let prompt = "Call: \(call.title ?? call.app + " call") on \(formatter.string(from: call.date))\n"
            + (people.isEmpty ? "" : "To: \(people.joined(separator: ", "))\n")
            + "\nNotes:\n\(call.summary)\n"
            + (promises.isEmpty ? "" : "\nPromises:\n\(promises)\n")
            + "\nWrite the email now."
        let reply = try await ChatService.complete(key: key, system: CallProcessor.followUpSystem, prompt: prompt, json: false, maxTokens: 700)
        guard let draft = CallProcessor.parseEmail(reply) else {
            Log.warn("followup", "The AI's reply could not be read as an email (\(reply.count) characters)")
            throw ChatError.message("I couldn't write that email. Try again.")
        }
        return draft
    }
}
