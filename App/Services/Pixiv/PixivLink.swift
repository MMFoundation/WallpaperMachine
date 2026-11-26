import Foundation

/// A pixiv illustration named by what the user pasted: its web URL or its bare numeric id.
/// Links are read as URLs, never by a pattern over free text, so a sentence that merely holds
/// digits or a URL is still a tag search.
enum PixivLink {
    /// A bare number names an illustration from this many digits on, so short numbers such as
    /// years or character counts stay tag searches.
    static let minimumBareDigits = 6
    /// Maximum accepted bare or linked illustration id length, matching `PixivWork.isValidID`.
    static let maximumDigits = 12

    /// The illustration id `text` names: a bare numeric id (>= 6 digits) or a pixiv artwork link.
    /// Returns nil for tag searches and any unrecognized or malformed input.
    static func illustID(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.utf8.count >= minimumBareDigits, trimmed.utf8.count <= maximumDigits,
            trimmed.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
        {
            return canonical(trimmed)
        }
        return illustID(inLink: trimmed)
    }

    /// Whether `text` alone is a bare numeric illustration id (>= 6 ASCII digits, non-zero,
    /// without leading zeros).
    static func isBareIllustID(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= minimumBareDigits, trimmed.utf8.count <= maximumDigits,
            trimmed.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
        else { return false }
        return canonical(trimmed) == trimmed
    }

    /// The illustration id a pixiv link names; a bare id is not a link.
    ///
    /// Accepted forms:
    /// - `https://www.pixiv.net/artworks/<id>` (and `http://`, or without `www.`)
    /// - `https://www.pixiv.net/en/artworks/<id>` (and other 2–5 character locale prefixes)
    /// - `https://www.pixiv.net/member_illust.php?...&illust_id=<id>`
    /// - `pixiv.net/i/<id>` (with or without `https://` / `http://` / `www.`)
    static func illustID(inLink text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2048, !trimmed.contains(where: \.isWhitespace)
        else { return nil }
        let lowered = trimmed.lowercased()
        let normalized: String
        if lowered.hasPrefix("pixiv.net/") || lowered.hasPrefix("www.pixiv.net/") {
            normalized = "https://" + trimmed
        } else {
            normalized = trimmed
        }
        guard let link = URLComponents(string: normalized),
            link.user == nil, link.password == nil, link.port == nil,
            let scheme = link.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = link.host?.lowercased(), host == "pixiv.net" || host == "www.pixiv.net"
        else { return nil }

        let segments = link.path.split(separator: "/").map { $0.lowercased() }
        switch segments.count {
        case 1:
            guard segments[0] == "member_illust.php" else { return nil }
            return (link.queryItems ?? []).first { $0.name == "illust_id" }?.value.flatMap(canonical)
        case 2:
            guard segments[0] == "artworks" || segments[0] == "i" else { return nil }
            return canonical(segments[1])
        case 3:
            guard isLocaleSegment(segments[0]), segments[1] == "artworks" else { return nil }
            return canonical(segments[2])
        default:
            return nil
        }
    }

    /// A locale path segment such as `en`, `ja`, `ko`, `zh-cn`, `zh-tw`.
    private static func isLocaleSegment(_ segment: String) -> Bool {
        guard (2...5).contains(segment.utf8.count), !segment.hasPrefix("-"), !segment.hasSuffix("-")
        else { return false }
        return segment.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || $0 == 45 }
    }

    /// Canonical decimal illustration id: 1 to 12 ASCII digits, above zero, leading zeros stripped.
    private static func canonical(_ digits: String) -> String? {
        guard (1...maximumDigits).contains(digits.utf8.count),
            digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let value = UInt64(digits), value > 0
        else { return nil }
        let string = String(value)
        return PixivWork.isValidID(string) ? string : nil
    }
}
