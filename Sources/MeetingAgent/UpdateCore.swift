import Foundation

/// A version such as 1.4.2, read from a release tag such as "v1.4.2".
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("v") { cleaned.removeFirst() }
        // Ignore anything after a dash or plus, like 1.2.0-beta.
        cleaned = String(cleaned.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? "")
        let numbers = cleaned.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(where: { $0 == nil }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let length = max(a.parts.count, b.parts.count)
        for index in 0..<length {
            let left = index < a.parts.count ? a.parts[index] : 0
            let right = index < b.parts.count ? b.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

struct ReleaseInfo: Equatable {
    var tag: String
    var version: AppVersion
    var pageURL: URL?
    var notes: String
    var assets: [(name: String, url: URL)]

    static func == (a: ReleaseInfo, b: ReleaseInfo) -> Bool {
        a.tag == b.tag && a.version == b.version && a.pageURL == b.pageURL && a.notes == b.notes
            && a.assets.map { $0.name } == b.assets.map { $0.name }
    }

    /// Reads GitHub's "latest release" answer. Drafts and pre-releases are ignored.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = AppVersion(tag) else { return nil }
        if (object["draft"] as? Bool) == true || (object["prerelease"] as? Bool) == true { return nil }
        let assets: [(name: String, url: URL)] = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset in
            guard let name = asset["name"] as? String,
                  let link = asset["browser_download_url"] as? String,
                  let url = URL(string: link) else { return nil }
            return (name, url)
        }
        return ReleaseInfo(
            tag: tag,
            version: version,
            pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)),
            notes: (object["body"] as? String) ?? "",
            assets: assets
        )
    }

    /// The installer that matches this Mac: "…-arm64.dmg" for Apple silicon, "…-intel.dmg" for Intel.
    func installer(appleSilicon: Bool) -> URL? {
        let wanted = appleSilicon ? "arm64" : "intel"
        return assets.first { $0.name.lowercased().hasSuffix(".dmg") && $0.name.lowercased().contains(wanted) }?.url
    }

    /// The first line of the release notes, trimmed to something that fits in a banner.
    var headline: String {
        let line = notes.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-* \t")) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 110 ? String(line.prefix(110)) + "…" : line
    }
}

enum UpdateDecision {
    /// True when `latest` is newer than what is installed. A build with an unreadable version never nags.
    static func isNewer(latest: String, installed: String) -> Bool {
        guard let a = AppVersion(latest), let b = AppVersion(installed) else { return false }
        return a > b
    }

    /// At most one reminder a day for the same version.
    static func shouldRemind(lastReminded: Date?, now: Date = Date()) -> Bool {
        guard let lastReminded else { return true }
        return now.timeIntervalSince(lastReminded) > 20 * 3600
    }
}
