import Foundation

enum AppUpdateConfiguration {
    static let repositoryURL = URL(string: "https://github.com/WallpaperMachine/WallpaperMachine")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let bundleIdentifier = "app.wallpapermachine"

    /// Apple's Developer ID chain for the project's team (`anchor apple generic`, the Developer
    /// ID intermediate and leaf markers, team DT6YQU64FF): what releases are signed and
    /// notarized with. It names the team, not a certificate, so renewing the Developer ID
    /// certificate changes neither this nor the releases' designated requirement.
    static let developerIDRequirement = #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]"#
        + #" and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "DT6YQU64FF""#
}

struct SemanticVersion: Comparable, Equatable, Codable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) && ($0 == "0" || !$0.hasPrefix("0")) }),
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var display: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// What a release body says, reduced to the headings and lines a panel can show.
///
/// `scripts/release_notes.py` writes the body from the commits between two tags and
/// ends the part meant for the app with ``boundary``; everything after it is download
/// instructions rather than release notes. A hand-written body still parses: any
/// heading starts a section and any other line becomes one of its lines.
struct ReleaseNotes: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        let title: String
        let items: [String]
        /// Bullet items, as opposed to a paragraph such as a release's summary.
        var isList = false

        /// Feature-release highlights keep their emphasis in every notes translation.
        var isHighlights: Bool { title == "Highlights" || title == "亮点" || title == "주요 변경 사항" }
    }

    static let boundary = "<!-- release-notes-end -->"

    let version: String
    let sections: [Section]

    init?(version: String, body: String) {
        let sections = Self.parse(body)
        guard !sections.isEmpty else { return nil }
        self.version = version
        self.sections = sections
    }

    static func parse(_ body: String) -> [Section] {
        let text = body.components(separatedBy: boundary).first ?? body
        var sections: [Section] = []
        var title = ""
        var items: [String] = []
        var bullets = false
        func flush(into next: String) {
            if !items.isEmpty {
                sections.append(Section(title: title, items: items, isList: bullets))
            }
            title = next
            items = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                flush(into: plain(trimmed.drop(while: { $0 == "#" })))
                continue
            }
            // The compare link is the page's navigation, not something to read here.
            if trimmed.hasPrefix("**Full changelog**") { continue }
            // A banner picture is shown, not read: its description is not a change.
            if trimmed.hasPrefix("![") { continue }
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
            // A paragraph after a list closes it; it is a remark, not another entry.
            if !items.isEmpty, isBullet != bullets { flush(into: "") }
            bullets = isBullet
            let source = isBullet ? trimmed.dropFirst(2) : trimmed[...]
            let item = plain(source)
            if !item.isEmpty { items.append(item) }
        }
        flush(into: "")
        return sections
    }

    /// A trailing group of reference links, `(closes [#76](…))` or `([abc1234](…), [def5678](…))`.
    private static let trailingReferences: String = {
        let link = #"(?:closes )?\[(?:#[0-9]+|`?[0-9a-f]{7,40}`?)\]\([^)]*\)"#
        return #"\s*\("# + link + #"(?:,\s*"# + link + #")*\)$"#
    }()

    /// Markdown reduced to the words: the trailing issue and commit references go, links keep
    /// their text, emphasis and code fences lose their markers.
    private static func plain(_ value: Substring) -> String {
        var text = String(value).trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: trailingReferences, options: .regularExpression) {
            text.removeSubrange(range)
        }
        text = text.replacingOccurrences(of: #"\s*\(`[0-9a-f]{7,40}`\)$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*{1,2}([^*]+)\*{1,2}"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
