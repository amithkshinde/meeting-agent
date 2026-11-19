import Foundation
import Security

/// Saves small secrets (the AI key, Notion token) so they survive updates without ever asking for a password.
/// The copy that counts is a private file only you can read (Application Support/MeetingAgent/secrets).
/// The macOS Keychain is tried too, but never in a way that can show a password window: an app signed without
/// a permanent certificate is a stranger to the Keychain after every update, and the prompt it caused froze the app.
enum SecureStore {
    private static let service = "com.amithshinde.meetingagent"

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingAgent/secrets", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base
    }

    private static func file(_ account: String) -> URL {
        folder.appendingPathComponent(account.replacingOccurrences(of: "/", with: "_"))
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Fail quietly instead of showing a password window.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    static func read(_ account: String) -> String? {
        if let data = try? Data(contentsOf: file(account)), let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        // Found in the Keychain from an older version: keep a private copy so this never depends on it again.
        write(text, account: account)
        return text
    }

    private static func write(_ value: String, account: String) {
        let url = file(account)
        try? Data(value.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func save(_ value: String, account: String) {
        write(value, account: account)
        // Best effort, and quiet. A stale item from an older build is left alone.
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { Log.write("kept the secret in a private file (Keychain status \(status))") }
    }

    static func delete(_ account: String) {
        try? FileManager.default.removeItem(at: file(account))
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

/// Stores the AI key.
enum Keychain {
    private static let account = "anthropic-api-key"
    static func read() -> String? { SecureStore.read(account) }
    static func save(_ value: String) { SecureStore.save(value, account: account) }
    static func delete() { SecureStore.delete(account) }
}

enum ChatError: LocalizedError {
    case badKey
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badKey: return "The API key was rejected. Paste a valid Google Gemini or Anthropic key."
        case .message(let text): return text
        }
    }
}

/// Asks Claude about the call so far. Only the transcript text is sent, never audio or video.
enum ChatService {
    /// Fast and cheap, which suits quick questions in the middle of a call.
    static let model = "claude-haiku-5-5"
    /// Free-tier model for people using a Google Gemini key.
    static let geminiModel = "gemini-3.8-flash"

    private static let system = """
    You are a discreet assistant helping the user during a live call. You get the transcript so far. \
    "You" is the user, and "Them" is everyone else on the call. Timestamps are minutes and seconds \
    since the recording started. The transcript comes from automatic speech recognition, so expect \
    small mistakes, and say so if something is unclear instead of guessing. Answer only from the \
    transcript and any background. Be brief and easy to scan, because the user is reading while the call goes on. Use \
    short bullet points for recaps. If something was asked of the user and not yet answered, say so. \
    You may also get background from the user's notes, files, emails and earlier calls. Each background source starts with a tag like [S1]. \
    After every fact you take from a source, add its tag in square brackets, for example [S2]. Use only tags that exist and cite only sources you used. \
    Facts from the current call's transcript have no tag, so say where in the call they came from, for example (this call, 05:12).
    """

    static func ask(
        key: String,
        transcript: String,
        now: String,
        memory: String = "",
        history: [(question: String, answer: String)],
        question: String
    ) async throws -> String {
        let transcriptText = transcript.isEmpty ? "(nothing has been said yet)" : transcript
        let earlier = memory.isEmpty ? "" : "Background from the user's notes, files and earlier calls:\n\(memory)\n\n"
        let prompt = earlier + "Transcript so far (current time in call: \(now)):\n\n\(transcriptText)\n\nQuestion: \(question)"
        return try await complete(key: key, system: system, history: history, prompt: prompt, json: false, maxTokens: 700)
    }

    /// One request to whichever AI service the saved key belongs to.
    static func complete(
        key: String,
        system: String,
        history: [(question: String, answer: String)] = [],
        prompt: String,
        json: Bool = false,
        maxTokens: Int = 1200
    ) async throws -> String {
        if key == AIAccess.localKey {
            return try await AIAccess.completeLocal(system: system, history: history, prompt: prompt)
        }
        if key.hasPrefix("sk-ant-") {
            return try await askClaude(key: key, system: system, history: history, prompt: prompt, maxTokens: maxTokens)
        }
        GeminiBudget.record()
        return try await askGemini(key: key, system: system, history: history, prompt: prompt, json: json, maxTokens: maxTokens)
    }

    private static func askClaude(
        key: String,
        system: String,
        history: [(question: String, answer: String)],
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        var messages: [[String: String]] = []
        for turn in history.suffix(6) {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChatError.message("Couldn't reach the AI service: \(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 401 { throw ChatError.badKey }
        guard status == 200 else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "status \(status)"
            Log.write("chat request failed: \(detail)")
            throw ChatError.message("The AI service said: \(detail)")
        }
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw ChatError.message("The AI service sent an empty answer.") }
        return text
    }

    private static func askGemini(
        key: String,
        system: String,
        history: [(question: String, answer: String)],
        prompt: String,
        json: Bool,
        maxTokens: Int
    ) async throws -> String {
        var contents: [[String: Any]] = []
        for turn in history.suffix(6) {
            contents.append(["role": "user", "parts": [["text": turn.question]]])
            contents.append(["role": "model", "parts": [["text": turn.answer]]])
        }
        contents.append(["role": "user", "parts": [["text": prompt]]])
        // Newer Gemini models spend part of this budget on thinking, so leave room.
        var generation: [String: Any] = ["maxOutputTokens": maxTokens * 3]
        if json { generation["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": generation,
        ]

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChatError.message("Couldn't reach the AI service: \(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 400 || status == 401 || status == 403 {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            if detail.lowercased().contains("api key") { throw ChatError.badKey }
        }
        guard status == 200 else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "status \(status)"
            Log.write("chat request failed: \(detail)")
            throw ChatError.message("The AI service said: \(detail)")
        }
        let candidates = json?["candidates"] as? [[String: Any]] ?? []
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw ChatError.message("The AI service sent an empty answer.") }
        return text
    }
}

/// Counts today's Gemini requests. Free Gemini keys allow only about 20 a day, so live suggestions
/// stop early and leave room for the summary after the call.
enum GeminiBudget {
    static let dailyLimit = 20
    static let reservedForSummary = 10

    private static var dayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "geminiRequests-" + formatter.string(from: Date())
    }

    static var usedToday: Int { UserDefaults.standard.integer(forKey: dayKey) }

    static func record() { UserDefaults.standard.set(usedToday + 1, forKey: dayKey) }

    static var liveSuggestionsAllowed: Bool { usedToday < dailyLimit - reservedForSummary }
}
