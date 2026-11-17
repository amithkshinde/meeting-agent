import SwiftUI

// MARK: - Applying the person's answers

enum VoiceApply {
    /// The person named a voice. Teaches the library and rewrites the transcript.
    @discardableResult
    static func answer(folder: URL, cluster: String, name: String) -> Bool {
        guard var review = VoiceReview.load(folder) else { return false }
        review.answer(cluster: cluster, name: name)
        guard let decision = review.decisions.first(where: { $0.id == cluster }), decision.status == .named,
              let found = review.clusters.first(where: { $0.id == cluster }) else { return false }
        Voices.library.learn(name: name, embedding: found.embedding, seconds: found.seconds, model: review.model)
        review.save(to: folder)
        rewrite(folder: folder, review: review)
        return true
    }

    /// The person chose not to name a voice. It stays "Speaker N" and the question goes away.
    static func skip(folder: URL, cluster: String) {
        guard var review = VoiceReview.load(folder),
              let index = review.decisions.firstIndex(where: { $0.id == cluster }) else { return }
        review.decisions[index].status = .unknown
        review.decisions[index].why = "you skipped it"
        review.save(to: folder)
    }

    /// Writes transcript.txt again from the saved sentences, with the current names.
    static func rewrite(folder: URL, review: VoiceReview) {
        let turns = VoiceTurns.load(folder)
        guard !turns.isEmpty else { return }
        let labels = VoiceResolver.labels(for: review.decisions, clusters: review.clusters)
        let text = VoiceTranscript.render(turns, labels: labels)
        guard text.count > 20 else { return }
        try? text.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("transcript-clean.txt"))
    }
}

// MARK: - "Who's who?" on a call page

/// Shown at the top of the transcript when some voices could not be named with confidence.
struct VoiceReviewCard: View {
    let folder: URL
    let attendees: [String]
    var onChange: () -> Void

    @State private var review: VoiceReview?
    @State private var names: [String: String] = [:]

    private var pending: [VoiceDecision] { review?.pending ?? [] }

    private var options: [String] {
        var seen: [String] = []
        for name in attendees + Voices.library.profiles.map({ $0.name }) where !seen.contains(where: { VoiceNames.same($0, name) }) {
            seen.append(name)
        }
        return seen
    }

    private func label(_ decision: VoiceDecision) -> String {
        guard let review else { return decision.id }
        let labels = VoiceResolver.labels(for: review.decisions, clusters: review.clusters)
        let minutes = Int((decision.seconds / 60).rounded(.down))
        let seconds = Int(decision.seconds) % 60
        let spoke = minutes > 0 ? "\(minutes) min \(seconds) s" : "\(seconds) s"
        return "\(labels[decision.id] ?? decision.id) · spoke for \(spoke)"
    }

    var body: some View {
        Group {
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Who's who?").font(.headline)
                    Text("I couldn't be sure about these voices. Tell me who they are and I'll remember their voice for next time. The voice fingerprint stays on this Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(pending) { decision in row(decision) }
                }
                .card()
            }
        }
        .onAppear { reload() }
    }

    private func row(_ decision: VoiceDecision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label(decision)).font(.subheadline.bold())
            if let quote = decision.quote {
                Text("“\(quote)”").font(.callout).italic().fixedSize(horizontal: false, vertical: true)
            }
            if !decision.why.isEmpty {
                Text(decision.why.prefix(1).uppercased() + String(decision.why.dropFirst()) + ".")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("Name", text: Binding(get: { names[decision.id] ?? "" }, set: { names[decision.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                if !options.isEmpty {
                    Menu("Pick") {
                        ForEach(options, id: \.self) { name in
                            Button(name) { names[decision.id] = name }
                        }
                    }
                    .fixedSize()
                }
                Button("Save") { save(decision) }
                    .buttonStyle(.borderedProminent)
                    .disabled((names[decision.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Skip") { skip(decision) }
                    .buttonStyle(SoftButtonStyle())
            }
        }
    }

    private func reload() {
        review = VoiceReview.load(folder)
        for decision in review?.pending ?? [] where names[decision.id] == nil {
            names[decision.id] = decision.suggestion ?? ""
        }
    }

    private func save(_ decision: VoiceDecision) {
        let name = (names[decision.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        VoiceApply.answer(folder: folder, cluster: decision.id, name: name)
        reload()
        onChange()
    }

    private func skip(_ decision: VoiceDecision) {
        VoiceApply.skip(folder: folder, cluster: decision.id)
        reload()
    }
}

// MARK: - Settings: remembered voices

struct VoicesCard: View {
    @State private var on = Voices.isOn
    @State private var profiles: [VoiceProfile] = Voices.library.profiles
    @State private var names: [String: String] = [:]
    @State private var confirmForgetAll = false
    @State private var crashed = Voices.crashed

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voices").font(.headline)
            Toggle(isOn: Binding(get: { on }, set: { value in
                on = value
                Voices.isOn = value
                if value { Voices.crashed = false; crashed = false }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recognise people by their voice")
                    Text("After a call, I tell the voices apart and put names on them, using the names seen on the call screen and the voices I remember. When I'm not sure, I ask you. Needs the call to have been transcribed with Parakeet.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if crashed {
                Text("Voice recognition stopped last time before it finished, so it was switched off. Turn it back on to try again.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if profiles.isEmpty {
                Text("No voices remembered yet. They appear here after a call, once someone has been named.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(profiles) { profile in
                        HStack(spacing: 8) {
                            TextField("Name", text: Binding(get: { names[profile.id] ?? profile.name }, set: { names[profile.id] = $0 }), onCommit: { commitRename(profile) })
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                            Text("\(profile.calls) call\(profile.calls == 1 ? "" : "s") · \(Int((profile.seconds / 60).rounded())) min")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget") {
                                Voices.library.remove(id: profile.id)
                                refresh()
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                    }
                    Button("Forget all voices") { confirmForgetAll = true }
                        .buttonStyle(SoftButtonStyle())
                }
            }

            Text("A voice fingerprint is a list of numbers, not a recording. It is stored only on this Mac and never uploaded. Because it identifies a person, it's fair to tell the people on your calls that you do this.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .card()
        .onAppear { refresh() }
        .confirmationDialog("Forget every remembered voice?", isPresented: $confirmForgetAll) {
            Button("Forget all", role: .destructive) {
                Voices.library.removeAll()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Past transcripts keep their names. Future calls will ask again.")
        }
    }

    private func refresh() {
        profiles = Voices.library.profiles
        names = [:]
        crashed = Voices.crashed
        on = Voices.isOn
    }

    private func commitRename(_ profile: VoiceProfile) {
        let name = (names[profile.id] ?? profile.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != profile.name else { return }
        Voices.library.rename(id: profile.id, to: name)
        refresh()
    }
}
