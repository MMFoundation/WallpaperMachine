import Foundation

/// Custom user-bindable action target for a `usershortcut` wallpaper property.
///
/// Only targets explicitly chosen and approved by the user in `UserShortcutStore` may be
/// executed. Built-in media transport keys (`media:playpause`, `media:next`, `media:previous`)
/// remain handled by `SystemMediaCommand`.
enum UserShortcutTarget: Equatable, Hashable, Codable, Sendable {
    case application(bundleID: String)
    case shortcut(name: String)

    static let applicationPrefix = "app:"
    static let shortcutPrefix = "shortcut:"
    static let maximumIdentifierLength = 256

    var rawValue: String {
        switch self {
        case .application(let bundleID): "\(Self.applicationPrefix)\(bundleID)"
        case .shortcut(let name): "\(Self.shortcutPrefix)\(name)"
        }
    }

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.applicationPrefix) {
            let bundleID = String(rawValue.dropFirst(Self.applicationPrefix.count))
            guard Self.isValidBundleIdentifier(bundleID) else { return nil }
            self = .application(bundleID: bundleID)
        } else if rawValue.hasPrefix(Self.shortcutPrefix) {
            let name = String(rawValue.dropFirst(Self.shortcutPrefix.count))
            guard Self.isValidShortcutName(name) else { return nil }
            self = .shortcut(name: name)
        } else {
            return nil
        }
    }

    var isValid: Bool {
        switch self {
        case .application(let bundleID): Self.isValidBundleIdentifier(bundleID)
        case .shortcut(let name): Self.isValidShortcutName(name)
        }
    }

    /// Strict reverse-DNS macOS bundle identifier validation: ASCII alphanumeric plus `.`, `-`, `_`,
    /// bounded length, no path separators, whitespace, control characters, or `..`.
    static func isValidBundleIdentifier(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, bundleID.unicodeScalars.count <= maximumIdentifierLength,
              !bundleID.hasPrefix("."), !bundleID.hasSuffix("."),
              !bundleID.hasPrefix("-"), !bundleID.hasSuffix("-"),
              !bundleID.contains("..")
        else { return false }
        return bundleID.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar == "." || scalar == "-" || scalar == "_"
            )
        }
    }

    /// Strict Apple Shortcut name validation: non-empty, trimmed, bounded Unicode scalar length,
    /// no Unicode control characters or line/paragraph separators (`U+2028`/`U+2029`), and no
    /// leading `-` so `/usr/bin/shortcuts run <name>` can never interpret the name as a CLI flag.
    static func isValidShortcutName(_ name: String) -> Bool {
        guard !name.isEmpty, name.unicodeScalars.count <= maximumIdentifierLength,
              name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
              !name.hasPrefix("-")
        else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control
                && scalar.value != 0x2028
                && scalar.value != 0x2029
        }
    }
}

/// Stable composite key identifying one `usershortcut` property on one wallpaper.
struct UserShortcutKey: Equatable, Hashable, Codable, Sendable {
    let wallpaperID: String
    let propertyID: String

    static let maximumFieldLength = 512

    /// Length-delimited storage key so punctuation inside IDs can never alias another entry.
    var storageKey: String {
        "\(wallpaperID.utf8.count):\(wallpaperID)|\(propertyID.utf8.count):\(propertyID)"
    }

    var isValid: Bool {
        Self.isValidField(wallpaperID) && Self.isValidField(propertyID)
    }

    private static func isValidField(_ field: String) -> Bool {
        !field.isEmpty && field.count <= maximumFieldLength
            && !field.contains("\0") && !field.contains(where: \.isNewline)
    }
}

/// One user-chosen, explicitly approved `app:` or `shortcut:` binding for a wallpaper property.
struct ApprovedUserShortcutBinding: Equatable, Hashable, Codable, Sendable {
    let wallpaperID: String
    let propertyID: String
    let target: UserShortcutTarget
    /// Human-readable application name captured at pick time (shown via `Text(verbatim:)`).
    let displayName: String?
    let approvedAt: Date

    var key: UserShortcutKey { UserShortcutKey(wallpaperID: wallpaperID, propertyID: propertyID) }
    var rawValue: String { target.rawValue }

    var isValid: Bool {
        guard key.isValid, target.isValid else { return false }
        if let displayName {
            guard !displayName.isEmpty, displayName.count <= UserShortcutTarget.maximumIdentifierLength,
                  !displayName.contains("\0"), !displayName.contains(where: \.isNewline)
            else { return false }
        }
        return true
    }
}

/// Recognizes `usershortcut` property descriptors emitted by the bridge without extending the
/// UniFFI schema: `manifest.rs` always represents `usershortcut` as a `Combo` with these four
/// built-in transport choices in order.
enum UserShortcutDescriptor {
    static let builtInValues: [BridgePropertyValue] = [
        .string(value: ""),
        .string(value: SystemMediaCommand.togglePlayPause.rawValue),
        .string(value: SystemMediaCommand.nextTrack.rawValue),
        .string(value: SystemMediaCommand.previousTrack.rawValue),
    ]

    static func isUserShortcut(_ descriptor: BridgePropertyDescriptor) -> Bool {
        descriptor.kind == .combo && descriptor.comboOptions.map(\.value) == builtInValues
    }

    static func isBuiltInValue(_ value: BridgePropertyValue) -> Bool {
        builtInValues.contains(value)
    }
}

struct UserShortcutStoreError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Persisted allowlist of explicitly user-approved `app:` and `shortcut:` bindings per
/// `(wallpaperID, propertyID)`.
///
/// Hard security invariant: an author-supplied `app:` or `shortcut:` default in `project.json`
/// is NEVER added to this store and therefore can NEVER execute. Only explicit user actions in
/// the Inspector write entries through `approve(...)`.
@MainActor
final class UserShortcutStore {
    static let shared = UserShortcutStore()
    nonisolated static let storageKey = "WallpaperMachine.approvedUserShortcuts"
    static let didChangeNotification = Notification.Name("WallpaperMachine.approvedUserShortcutsChanged")
    nonisolated static let maximumBindings = 512
    nonisolated static let maximumArchiveBytes = 512 * 1024

    private let defaults: UserDefaults
    private var entries: [String: ApprovedUserShortcutBinding]

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        self.entries = Self.load(from: defaults)
    }

    func binding(wallpaperID: String, propertyID: String) -> ApprovedUserShortcutBinding? {
        entries[UserShortcutKey(wallpaperID: wallpaperID, propertyID: propertyID).storageKey]
    }

    func bindings(for wallpaperID: String) -> [String: ApprovedUserShortcutBinding] {
        var result: [String: ApprovedUserShortcutBinding] = [:]
        for entry in entries.values where entry.wallpaperID == wallpaperID {
            result[entry.propertyID] = entry
        }
        return result
    }

    func allBindings() -> [ApprovedUserShortcutBinding] {
        entries.values.sorted {
            ($0.wallpaperID, $0.propertyID) < ($1.wallpaperID, $1.propertyID)
        }
    }

    /// Explicitly approves and persists `target` for `(wallpaperID, propertyID)`.
    @discardableResult
    func approve(
        wallpaperID: String,
        propertyID: String,
        target: UserShortcutTarget,
        displayName: String? = nil,
        now: Date = Date()
    ) throws -> ApprovedUserShortcutBinding {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = (trimmedName?.isEmpty == false) ? trimmedName : nil
        let binding = ApprovedUserShortcutBinding(
            wallpaperID: wallpaperID,
            propertyID: propertyID,
            target: target,
            displayName: normalizedName,
            approvedAt: now)
        guard binding.isValid else {
            throw UserShortcutStoreError(
                message: String(localized: "Choose a valid application or Shortcut name."))
        }
        let storageKey = binding.key.storageKey
        guard entries[storageKey] != nil || entries.count < Self.maximumBindings else {
            throw UserShortcutStoreError(
                message: String(localized: "Too many shortcut bindings are saved."))
        }
        entries[storageKey] = binding
        persist()
        changed()
        return binding
    }

    /// Removes the user-approved binding for `(wallpaperID, propertyID)`, if any.
    func remove(wallpaperID: String, propertyID: String) {
        let storageKey = UserShortcutKey(wallpaperID: wallpaperID, propertyID: propertyID).storageKey
        guard entries.removeValue(forKey: storageKey) != nil else { return }
        persist()
        changed()
    }

    /// Removes all saved approvals for a removed wallpaper.
    func removeAll(for wallpaperID: String) {
        removeAll(for: Set([wallpaperID]))
    }

    /// Removes all saved approvals for the given wallpapers.
    func removeAll(for wallpaperIDs: Set<String>) {
        guard !wallpaperIDs.isEmpty else { return }
        let before = entries.count
        entries = entries.filter { !wallpaperIDs.contains($0.value.wallpaperID) }
        guard entries.count != before else { return }
        persist()
        changed()
    }

    /// Returns whether approving `(wallpaperID, propertyID)` stays within `maximumBindings`,
    /// counting additional staged additions that are not yet persisted.
    func canApprove(
        wallpaperID: String,
        propertyID: String,
        additionalStagedCount: Int = 0
    ) -> Bool {
        let key = UserShortcutKey(wallpaperID: wallpaperID, propertyID: propertyID).storageKey
        if entries[key] != nil { return true }
        return entries.count + max(0, additionalStagedCount) < Self.maximumBindings
    }

    /// Returns true if and only if the user explicitly approved `target` for the exact
    /// `(wallpaperID, propertyID)` pair. Never falls back across wallpapers.
    func isApproved(wallpaperID: String, propertyID: String, target: UserShortcutTarget) -> Bool {
        guard !wallpaperID.isEmpty,
              let existing = binding(wallpaperID: wallpaperID, propertyID: propertyID)
        else {
            return false
        }
        return existing.target == target
    }

    private static func load(from defaults: UserDefaults) -> [String: ApprovedUserShortcutBinding] {
        guard let data = defaults.data(forKey: storageKey), data.count <= maximumArchiveBytes,
              let decoded = try? JSONDecoder().decode([String: ApprovedUserShortcutBinding].self, from: data)
        else { return [:] }
        var valid: [String: ApprovedUserShortcutBinding] = [:]
        for (key, binding) in decoded where binding.isValid && key == binding.key.storageKey {
            if valid.count >= maximumBindings { break }
            valid[key] = binding
        }
        return valid
    }

    private func persist() {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
