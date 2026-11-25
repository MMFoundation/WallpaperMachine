import Foundation

/// A choice shared by scheduled changes, appearance rules and Focus filters.
struct WallpaperAutomationTarget: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case wallpaper, playlist }
    let kind: Kind
    let id: String

    var isValid: Bool { !id.isEmpty && id.count <= 1024 && !id.contains("\0") }
}

struct WallpaperAutomationRule: Codable, Equatable, Identifiable, Sendable {
    enum Event: String, Codable, CaseIterable, Sendable { case time, sunrise, sunset }
    var id = UUID().uuidString
    var weekdays: Set<Int> = Set(1...7) // Gregorian Calendar weekday: Sunday is 1.
    var event: Event = .time
    var minute = 8 * 60
    var offset = 0
    var target: WallpaperAutomationTarget
    var isEnabled = true

    init(
        id: String = UUID().uuidString,
        weekdays: Set<Int> = Set(1...7),
        event: Event = .time,
        minute: Int = 8 * 60,
        offset: Int = 0,
        target: WallpaperAutomationTarget,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.weekdays = weekdays
        self.event = event
        self.minute = minute
        self.offset = offset
        self.target = target
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, weekdays, event, minute, offset, target, isEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        weekdays = try values.decode(Set<Int>.self, forKey: .weekdays)
        event = try values.decode(Event.self, forKey: .event)
        minute = try values.decode(Int.self, forKey: .minute)
        offset = try values.decode(Int.self, forKey: .offset)
        target = try values.decode(WallpaperAutomationTarget.self, forKey: .target)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    var isValid: Bool {
        !id.isEmpty && id.count <= 128 && !id.contains("\0") && !weekdays.isEmpty
            && weekdays.isSubset(of: Set(1...7)) && (0..<1440).contains(minute)
            && (-180...180).contains(offset) && target.isValid
    }
}

struct DisplayWallpaperAutomation: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case off, schedule, appearance, spaces }

    /// The automatic rule active on this display, independent of whether per-desktop (Space)
    /// overrides are enabled.
    enum RuleMode: String, Codable, CaseIterable, Sendable { case off, schedule, appearance }

    var mode: Mode = .off
    /// Whether per-desktop (Space) overrides are enabled on this display. May be combined with
    /// `.schedule` or `.appearance` so desktops without a chosen wallpaper follow those rules.
    var spacesEnabled: Bool = false
    var rules: [WallpaperAutomationRule] = []
    var light: WallpaperAutomationTarget?
    var dark: WallpaperAutomationTarget?
    var revision: UInt64 = 0
    var spaces: [String: WallpaperAutomationTarget] = [:]
    /// Optional wallpaper or saved playlist override while running on battery power.
    var batteryTarget: WallpaperAutomationTarget?

    /// True when per-desktop (Space) choices are active, either standalone (`.spaces` / legacy
    /// records) or stacked alongside a schedule or appearance rule (`spacesEnabled`).
    var usesSpaces: Bool { mode == .spaces || spacesEnabled }

    /// The active schedule or appearance rule, if any.
    var ruleMode: RuleMode {
        switch mode {
        case .schedule: .schedule
        case .appearance: .appearance
        case .off, .spaces: .off
        }
    }

    /// What a desktop shows when per-desktop choices are active: its own explicit choice first;
    /// otherwise the stacked schedule/appearance target when a rule mode is active, or Desktop 1's
    /// choice in standalone Space mode so Mission Control and the live wallpaper agree. Nil when
    /// nothing applies: the display keeps what it shows.
    func desktopTarget(
        _ space: String, firstDesktop: String?, ruleFallback: WallpaperAutomationTarget? = nil
    ) -> WallpaperAutomationTarget? {
        if let explicit = spaces[space] { return explicit }
        if ruleMode != .off { return ruleFallback }
        return firstDesktop.flatMap { spaces[$0] }
    }

    var isValid: Bool {
        rules.count <= 64 && Set(rules.map(\.id)).count == rules.count
            && rules.allSatisfy(\.isValid) && light?.isValid != false && dark?.isValid != false
            && batteryTarget?.isValid != false
            && spaces.count <= 128 && spaces.allSatisfy { !$0.key.isEmpty && $0.key.count <= 128
                && !$0.key.contains(where: { $0.isNewline || $0 == "\0" }) && $0.value.isValid }
    }
}

extension DisplayWallpaperAutomation {
    private enum CodingKeys: String, CodingKey {
        case mode, spacesEnabled, rules, light, dark, revision, spaces, batteryTarget
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(Mode.self, forKey: .mode)
        spacesEnabled = try values.decodeIfPresent(Bool.self, forKey: .spacesEnabled) ?? (mode == .spaces)
        rules = try values.decode([WallpaperAutomationRule].self, forKey: .rules)
        light = try values.decodeIfPresent(WallpaperAutomationTarget.self, forKey: .light)
        dark = try values.decodeIfPresent(WallpaperAutomationTarget.self, forKey: .dark)
        revision = try values.decode(UInt64.self, forKey: .revision)
        spaces = try values.decodeIfPresent([String: WallpaperAutomationTarget].self, forKey: .spaces) ?? [:]
        batteryTarget = try values.decodeIfPresent(WallpaperAutomationTarget.self, forKey: .batteryTarget)
    }
}

struct WallpaperSolarLocation: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// Where the sun rules take their times from: coordinates the user typed, clock times the
/// user fixed, or coordinates the system keeps up to date.
enum WallpaperSolarSource: String, Codable, CaseIterable, Sendable {
    case coordinates, fixed, automatic
}

/// The Sunrise and sunset settings. `location` is what the coordinates and automatic sources
/// plan with; the fixed source ignores it and uses the two clock times instead.
struct WallpaperSolarSettings: Codable, Equatable, Sendable {
    var source: WallpaperSolarSource = .coordinates
    var location: WallpaperSolarLocation?
    var fixedSunriseMinute: Int = 7 * 60
    var fixedSunsetMinute: Int = 18 * 60

    var isValid: Bool {
        (0..<1440).contains(fixedSunriseMinute) && (0..<1440).contains(fixedSunsetMinute)
            && location?.isValid != false
    }

    /// The coordinates the solar maths may use; nil for fixed times and when none is known.
    var planningLocation: WallpaperSolarLocation? {
        source == .fixed ? nil : location
    }
}

struct WallpaperAutomationOccurrence: Equatable, Sendable {
    let key: String
    let date: Date
    let target: WallpaperAutomationTarget
}

/// Calendar rules are evaluated against the local civil day, including DST and solar offsets.
enum WallpaperAutomationPlanner {
    struct Result {
        var current: WallpaperAutomationOccurrence?
        var next: WallpaperAutomationOccurrence?
        var reevaluateAt: Date
    }

    static func resolve(_ configuration: DisplayWallpaperAutomation, now: Date, dark: Bool,
                        solar: WallpaperSolarSettings?, calendar: Calendar = .autoupdatingCurrent) -> Result {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(24 * 3600)
        var result = Result(reevaluateAt: tomorrow)
        if configuration.ruleMode == .appearance {
            if let target = dark ? configuration.dark : configuration.light {
                result.current = .init(key: "appearance:\(configuration.revision):\(dark)", date: today, target: target)
            }
            return result
        }
        guard configuration.ruleMode == .schedule else { return result }
        var occurrences: [(Int, WallpaperAutomationOccurrence)] = []
        // One full week either side, plus a day for offsets crossing midnight.
        for dayOffset in -8...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            for (index, rule) in configuration.rules.enumerated() where rule.isEnabled && rule.weekdays.contains(weekday) {
                let date: Date?
                switch rule.event {
                case .time:
                    let match = calendar.nextDate(after: day.addingTimeInterval(-1),
                        matching: DateComponents(hour: rule.minute / 60, minute: rule.minute % 60, second: 0),
                        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
                    date = match.flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil }
                case .sunrise, .sunset:
                    let event: Date?
                    if solar?.source == .fixed, let solar {
                        let minute = rule.event == .sunrise ? solar.fixedSunriseMinute : solar.fixedSunsetMinute
                        event = calendar.nextDate(after: day.addingTimeInterval(-1),
                            matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
                            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
                            .flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil }
                    } else {
                        event = solar?.planningLocation.flatMap {
                            WallpaperSolarTimes.event(rule.event, on: day, location: $0, calendar: calendar)
                        }
                    }
                    date = event.map { $0.addingTimeInterval(TimeInterval(rule.offset * 60)) }
                }
                if let date {
                    occurrences.append((index, .init(key: "schedule:\(configuration.revision):\(rule.id):\(Int64(date.timeIntervalSince1970))", date: date, target: rule.target)))
                }
            }
        }
        occurrences.sort { a, b in a.1.date == b.1.date ? a.0 < b.0 : a.1.date < b.1.date }
        result.current = occurrences.last { $0.1.date <= now }?.1
        if let date = occurrences.first(where: { $0.1.date > now })?.1.date {
            // When events tie, the later rule is the single winning choice.
            result.next = occurrences.last { $0.1.date == date }?.1
            result.reevaluateAt = min(tomorrow, date)
        }
        return result
    }
}
