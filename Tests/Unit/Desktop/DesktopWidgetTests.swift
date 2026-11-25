import AppKit
import XCTest
@testable import WallpaperMachine

/// Desktop widgets: what each kind says or draws, where it sits on a display, when it next changes,
/// and how it is kept.
@MainActor
final class DesktopWidgetTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    /// Sunday, November 8 2026, 21:05:07 UTC.
    private let moment = Date(timeIntervalSince1970: 1_794_171_907)

    /// The words, with the narrow and no-break spaces the formats put before AM and PM made plain.
    private func text(_ widget: DesktopWidget, locale: Locale? = nil) -> String {
        DesktopWidgetRendering.text(
            for: widget, at: moment, locale: locale ?? english, timeZone: utc,
            formatters: DesktopWidgetRendering.Formatters())
        .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The Gregorian calendar of a region, in UTC, with that region's first weekday.
    private func calendar(_ locale: Locale? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale ?? english
        calendar.timeZone = utc
        return calendar
    }

    private func inputs(
        at date: Date? = nil, locale: Locale? = nil, battery: BatteryReading? = nil,
        solar: WallpaperSolarSettings? = nil
    ) -> DesktopWidgetRendering.Inputs {
        .init(
            date: date ?? moment, calendar: calendar(locale), locale: locale ?? english, battery: battery,
            solar: solar)
    }

    private func say(_ widget: DesktopWidget, _ inputs: DesktopWidgetRendering.Inputs) -> String {
        DesktopWidgetRendering.text(for: widget, inputs: inputs, formatters: DesktopWidgetRendering.Formatters())
    }

    // MARK: Words

    func testAClockFollowsTheChosenHourCycleAndShowsSecondsOnlyWhenAskedTo() {
        var clock = DesktopWidget(kind: .time)
        XCTAssertEqual(text(clock), "9:05 PM", "the system's own cycle for the region")
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "21:05")

        clock.timeFormat = .twentyFourHour
        XCTAssertEqual(text(clock), "21:05")
        clock.timeFormat = .twelveHour
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")).lowercased(), "9:05 pm")

        clock.showsSeconds = true
        XCTAssertEqual(text(clock), "9:05:07 PM")
    }

    func testAClockCanPadItsHourDropAMAndPMAndStackItsNumbers() {
        var clock = DesktopWidget(kind: .time)
        clock.padsHour = true
        XCTAssertEqual(text(clock), "09:05 PM")
        clock.showsPeriod = false
        XCTAssertEqual(text(clock), "09:05")
        clock.padsHour = false
        XCTAssertEqual(text(clock), "9:05")
        XCTAssertEqual(text(clock, locale: Locale(identifier: "ko_KR")), "9:05", "a period written first goes too")
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "21:05", "a 24-hour time has none")

        clock.clockLayout = .stacked
        XCTAssertEqual(text(clock), "9\n05")
        clock.showsPeriod = true
        clock.showsSeconds = true
        XCTAssertEqual(text(clock), "9\n05\n07\nPM")
        clock.text = "Home"
        clock.showsSeconds = false
        clock.showsPeriod = false
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "Home\n21\n05", "the label on its own line")

        XCTAssertEqual(
            DesktopWidgetRendering.adjusted("'at' h:mm a", padsHour: true, showsPeriod: false), "'at' hh:mm",
            "quoted words are kept")
    }

    func testTheLettersCaseSpacingAndSlantFollowTheWidget() throws {
        var date = DesktopWidget(kind: .date)
        date.textCase = .uppercase
        date.letterSpacing = 10
        date.isItalic = true
        date.typeface = .rounded
        let content = DesktopWidgetRendering.content(
            for: date, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        XCTAssertEqual(content.text, "Sunday, November 8", "the words themselves keep their case")
        guard case .text(let attributed) = content.drawing else { return XCTFail("text") }
        XCTAssertEqual(attributed.string, "SUNDAY, NOVEMBER 8")
        XCTAssertEqual(try XCTUnwrap(attributed.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat), 2.8, accuracy: 1e-6)
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let slanted = attributed.attribute(.obliqueness, at: 0, effectiveRange: nil) != nil
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.italic) || slanted, "an italic, or slanted letters")
    }

    func testAnInstalledFontFamilyIsUsedAndAMissingOneFallsBackToTheSystemFont() {
        var widget = DesktopWidget(kind: .text)
        widget.fontFamily = "Helvetica Neue"
        widget.weight = 700
        let font = DesktopWidgetRendering.font(for: widget)
        XCTAssertEqual(font.familyName, "Helvetica Neue")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "the family's bold")
        widget.fontFamily = "No Such Family 1234"
        XCTAssertEqual(
            DesktopWidgetRendering.font(for: widget).familyName, NSFont.systemFont(ofSize: 12).familyName)
        widget.font = .system(.serif)
        XCTAssertNil(widget.fontFamily, "choosing a design leaves the family")
    }

    func testEffectsWidenTheRoomAroundTheDrawingAndATurnWidensItsBox() {
        var widget = DesktopWidget(kind: .time)
        widget.hasShadow = false
        XCTAssertEqual(DesktopWidgetRendering.padding(for: widget), 1)
        XCTAssertNil(DesktopWidgetRendering.look(for: widget).shadow)
        widget.glowSize = 20
        XCTAssertEqual(DesktopWidgetRendering.padding(for: widget), ceil(96 * 0.2 * 1.5) + 1, "the glow's reach")
        widget.glowSize = 0
        widget.background = .rounded
        widget.backgroundPadding = 50
        XCTAssertEqual(DesktopWidgetRendering.padding(for: widget), 49, "the plate's")
        widget.hasShadow = true
        widget.shadowAngle = 90
        let shadow = DesktopWidgetRendering.look(for: widget).shadow
        XCTAssertEqual(shadow?.offset.width ?? 0, 96 * 0.02, accuracy: 1e-6, "falls to the right")
        XCTAssertEqual(shadow?.offset.height ?? 1, 0, accuracy: 1e-6)

        let content = DesktopWidgetRendering.Content(
            text: "", drawing: .text(NSAttributedString()), size: NSSize(width: 200, height: 100), padding: 0,
            look: .init(rotation: 90))
        XCTAssertEqual(content.boxSize, NSSize(width: 100, height: 200))
        widget.rotation = 90
        let frame = DesktopWidgetRendering.frame(for: content, widget: widget, display: display)
        XCTAssertEqual(frame.size, NSSize(width: 100, height: 200))
    }

    func testAStyleChangesOnlyTheLookAndResetPutsTheEffectsBack() {
        var widget = DesktopWidget(kind: .text)
        widget.text = "Hello"
        widget.size = 60
        widget.x = 0.2
        widget.fontFamily = "Avenir Next"
        widget.color = "#123456"
        DesktopWidget.StylePreset.neon.apply(to: &widget)
        XCTAssertEqual(widget.glowSize, 18)
        XCTAssertFalse(widget.hasShadow)
        XCTAssertEqual(widget.text, "Hello")
        XCTAssertEqual(widget.size, 60)
        XCTAssertEqual(widget.x, 0.2)
        XCTAssertEqual(widget.fontFamily, "Avenir Next")
        DesktopWidget.StylePreset.outlined.apply(to: &widget)
        XCTAssertEqual(widget.glowSize, 0, "a style starts from the default effects")
        XCTAssertEqual(widget.outlineWidth, 4)
        for preset in DesktopWidget.StylePreset.allCases {
            var styled = widget
            preset.apply(to: &styled)
            XCTAssertTrue(styled.isValid, "\(preset)")
        }
        widget.resetEffects()
        XCTAssertEqual(widget.outlineWidth, 0)
        XCTAssertTrue(widget.hasShadow)
        XCTAssertEqual(widget.color, "#FFFFFF", "the outlined style kept the neon's white")
    }

    func testADateIsWrittenInTheStyleChosenAndTheRegionsOrder() {
        var date = DesktopWidget(kind: .date)
        let expected: [DesktopWidget.DateStyle: String] = [
            .weekdayMonthDay: "Sunday, November 8", .monthDayYear: "November 8, 2026",
            .abbreviated: "Sun, Nov 8", .numeric: "11/8/2026", .weekday: "Sunday", .monthYear: "November 2026",
        ]
        for style in expected.keys {
            date.dateStyle = style
            XCTAssertEqual(text(date), expected[style], "\(style)")
        }
        date.dateStyle = .numeric
        XCTAssertEqual(text(date, locale: Locale(identifier: "de_DE")), "8.11.2026")
    }

    func testTheNewDateStylesCountWeeksAndDaysAsTheRegionDoes() {
        var date = DesktopWidget(kind: .date)
        date.dateStyle = .monthYear
        XCTAssertEqual(say(date, inputs()), "November 2026")
        date.dateStyle = .weekNumber
        XCTAssertEqual(say(date, inputs()), String(localized: "Week \("46")"), "US weeks start on Sunday")
        XCTAssertEqual(
            say(date, inputs(locale: Locale(identifier: "de_DE"))), String(localized: "Week \("45")"),
            "ISO weeks start on Monday")
        date.dateStyle = .dayOfYear
        XCTAssertEqual(say(date, inputs()), String(localized: "Day \("312")"))
    }

    func testADateCanBeWrittenInAnotherCalendarInThatCalendarsOwnWords() {
        var date = DesktopWidget(kind: .date)
        date.calendarSystem = .chinese
        date.dateStyle = .monthDayYear
        XCTAssertEqual(say(date, inputs(locale: Locale(identifier: "zh_Hans"))), "2026丙午年九月三十")
        date.dateStyle = .weekdayMonthDay
        XCTAssertEqual(say(date, inputs(locale: Locale(identifier: "zh_Hans"))), "九月三十星期日")
        date.calendarSystem = .hebrew
        XCTAssertEqual(say(date, inputs()), "Sunday, 28 Heshvan")
    }

    func testAClockOrADateCanShowAnotherTimeZoneAfterALabel() {
        var clock = DesktopWidget(kind: .time)
        clock.timeZone = "Asia/Tokyo"
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "06:05", "already the next morning")
        clock.text = "  Tokyo \n"
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "Tokyo 06:05", "the label on one line")

        var date = DesktopWidget(kind: .date)
        date.timeZone = "Asia/Tokyo"
        XCTAssertEqual(text(date), "Monday, November 9")
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [date]),
            Date(timeIntervalSince1970: 1_794_236_400), "midnight in Tokyo, 15:00 UTC")
    }

    func testATextWidgetKeepsItsLinesAndAlignsThemOnItsEdge() {
        var note = DesktopWidget(kind: .text)
        note.text = "Ship it\nthen rest"
        let content = DesktopWidgetRendering.content(
            for: note, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        XCTAssertEqual(content.text, "Ship it\nthen rest")
        var single = note
        single.text = "Ship it"
        let one = DesktopWidgetRendering.content(
            for: single, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        XCTAssertGreaterThan(content.size.height, one.size.height * 1.8, "two lines are twice as tall")
        note.alignment = .trailing
        guard case .text(let attributed) = DesktopWidgetRendering.content(
            for: note, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters()).drawing,
            let paragraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else { return XCTFail("text is drawn as text") }
        XCTAssertEqual(paragraph.alignment, .right)
        XCTAssertNil(DesktopWidgetRendering.nextChange(after: inputs(), widgets: [note]), "text never changes")
    }

    func testACountdownCountsWholeDaysToAndSinceItsDay() {
        var countdown = DesktopWidget(kind: .countdown, today: moment, calendar: calendar())
        XCTAssertEqual(countdown.targetDay, "2026-12-08", "a new one counts thirty days")
        countdown.targetDay = "2026-11-20"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "\(12) days until \("November 20")"))
        countdown.targetDay = "2027-01-01"
        XCTAssertEqual(
            say(countdown, inputs()), String(localized: "\(54) days until \("January 1, 2027")"),
            "another year's day says the year")
        countdown.text = "Launch"
        countdown.targetDay = "2026-11-09"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "1 day until \("Launch")"))
        countdown.targetDay = "2026-11-08"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "\("Launch") is today"))
        countdown.targetDay = "2026-11-07"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "1 day since \("Launch")"))
        countdown.targetDay = "2026-10-01"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "\(38) days since \("Launch")"))
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [countdown]),
            Date(timeIntervalSince1970: 1_794_182_400), "midnight")
    }

    func testAGreetingFollowsThePartOfTheDayAndChangesOnTheHour() {
        var greeting = DesktopWidget(kind: .greeting)
        func at(_ hour: Int) -> DesktopWidgetRendering.Inputs {
            inputs(at: Date(timeIntervalSince1970: 1_794_096_000 + Double(hour) * 3600))  // Nov 8 00:00 UTC
        }
        XCTAssertEqual(say(greeting, at(4)), String(localized: "Good night"))
        XCTAssertEqual(say(greeting, at(5)), String(localized: "Good morning"))
        XCTAssertEqual(say(greeting, at(12)), String(localized: "Good afternoon"))
        XCTAssertEqual(say(greeting, at(21)), String(localized: "Good evening"))
        greeting.text = "Alex"
        XCTAssertEqual(say(greeting, at(22)), String(localized: "Good night, \("Alex")"))
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [greeting]),
            Date(timeIntervalSince1970: 1_794_175_200), "22:00, when evening turns to night")
    }

    func testTheBatteryWidgetSaysHowFullTheBatteryIsAndWhetherItCharges() {
        let battery = DesktopWidget(kind: .battery)
        let percent = (0.82).formatted(.percent.locale(english))
        XCTAssertEqual(say(battery, inputs()), String(localized: "No battery"))
        XCTAssertEqual(
            say(battery, inputs(battery: .init(percent: 82, isDischarging: true))),
            String(localized: "Battery \(percent)"))
        XCTAssertEqual(
            say(battery, inputs(battery: .init(percent: 82, isDischarging: false))),
            String(localized: "Battery \(percent)"), "on power and held at a level, not charging")
        XCTAssertEqual(
            say(battery, inputs(battery: .init(percent: 82, isDischarging: false, isCharging: true))),
            String(localized: "Charging \(percent)"))
        XCTAssertNil(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [battery]),
            "the battery's notification redraws it, not a timer")
    }

    func testTheSunWidgetUsesTheAutomaticWallpapersSunriseAndSunset() throws {
        var sun = DesktopWidget(kind: .sun)
        sun.timeFormat = .twentyFourHour
        XCTAssertEqual(say(sun, inputs()), String(localized: "No location for sunrise and sunset"))
        XCTAssertNil(DesktopWidgetRendering.nextChange(after: inputs(), widgets: [sun]))

        var fixed = WallpaperSolarSettings()
        fixed.source = .fixed
        fixed.fixedSunriseMinute = 6 * 60 + 30
        fixed.fixedSunsetMinute = 22 * 60
        XCTAssertEqual(
            say(sun, inputs(solar: fixed)), String(localized: "Sunset \("22:00")"), "the next one, still today")
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(solar: fixed), widgets: [sun]),
            Date(timeIntervalSince1970: 1_794_175_200), "at sunset")
        sun.sunStyle = .both
        XCTAssertEqual(
            say(sun, inputs(solar: fixed)),
            String(localized: "Sunrise \("06:30")") + "  ·  " + String(localized: "Sunset \("22:00")"))

        let polar = WallpaperSolarSettings(location: WallpaperSolarLocation(latitude: 89, longitude: 0))
        XCTAssertEqual(say(sun, inputs(solar: polar)), String(localized: "No sunrise or sunset today"), "polar night")
        let london = WallpaperSolarSettings(location: WallpaperSolarLocation(latitude: 51.5, longitude: 0))
        let next = try XCTUnwrap(DesktopWidgetRendering.nextSunEvent(after: moment, solar: london, calendar: calendar()))
        XCTAssertEqual(next.0, .sunrise, "after a London sunset comes the next sunrise")
        XCTAssertEqual(next.1.timeIntervalSince(moment) / 3600, 10, accuracy: 1, "a little after seven")
    }

    func testAnAnalogClockPointsItsHandsAtTheTime() throws {
        var analog = DesktopWidget(kind: .analog)
        let content = DesktopWidgetRendering.content(
            for: analog, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        guard case .analog(let face) = content.drawing else { return XCTFail("a face, not text") }
        XCTAssertEqual(content.text, "21:05")
        XCTAssertEqual(face.hour, (9 + 5.0 / 60) / 12, accuracy: 1e-9)
        XCTAssertEqual(face.minute, 5.0 / 60, accuracy: 1e-9)
        XCTAssertNil(face.second)
        XCTAssertEqual(content.size, NSSize(width: 150, height: 150), "one and a half times its size across")

        analog.showsSeconds = true
        analog.timeZone = "Asia/Kolkata"
        let seconds = DesktopWidgetRendering.analogFace(for: analog, inputs: inputs())
        XCTAssertEqual(seconds.minute, (35 + 7.0 / 60) / 60, accuracy: 1e-9, "02:35:07 in India")
        XCTAssertEqual(try XCTUnwrap(seconds.second), 7.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [analog]),
            Date(timeIntervalSince1970: 1_794_171_908))
    }

    func testTheMonthCalendarPutsEachDayUnderItsWeekdayAndMarksToday() throws {
        let month = DesktopWidget(kind: .calendar)
        let content = DesktopWidgetRendering.content(
            for: month, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        XCTAssertEqual(content.text, "November 2026")
        guard case .text(let grid) = content.drawing else { return XCTFail("a grid of text") }
        let lines = grid.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 7, "the month, the weekdays and five weeks")
        XCTAssertEqual(lines[1], "\tS\tM\tT\tW\tT\tF\tS", "Sunday first in the US")
        XCTAssertEqual(lines[2], "\t1\t2\t3\t4\t5\t6\t7", "November 1 2026 is a Sunday")
        XCTAssertEqual(lines[6], "\t29\t30")
        let today = (grid.string as NSString).range(of: "\t8\t").location + 1
        XCTAssertNotNil(grid.attribute(.underlineStyle, at: today, effectiveRange: nil), "today is marked")
        XCTAssertNil(grid.attribute(.underlineStyle, at: today + 2, effectiveRange: nil))

        let monday = DesktopWidgetRendering.calendarGrid(
            for: month, inputs: inputs(locale: Locale(identifier: "de_DE")),
            formatters: DesktopWidgetRendering.Formatters())
        let weeks = monday.string.components(separatedBy: "\n")
        XCTAssertEqual(weeks[2], "\t\t\t\t\t\t\t1", "a Monday-first week puts Sunday last")
    }

    // MARK: Place

    private let display = NSRect(x: 0, y: 0, width: 1512, height: 982)

    func testThePositionNamesTheChosenEdgeOfTheTextAndItsVerticalCentre() {
        var widget = DesktopWidget(kind: .time)
        widget.x = 0.5
        widget.y = 0.25
        let size = NSSize(width: 200, height: 100)
        XCTAssertEqual(
            DesktopWidgetRendering.frame(textSize: size, padding: 10, widget: widget, display: display),
            NSRect(x: 646, y: 676, width: 220, height: 120), "centred on the point a quarter down the display")

        widget.alignment = .leading
        XCTAssertEqual(
            DesktopWidgetRendering.frame(textSize: size, padding: 10, widget: widget, display: display).minX + 10,
            756, "the text starts at the point")
        widget.alignment = .trailing
        XCTAssertEqual(
            DesktopWidgetRendering.frame(textSize: size, padding: 10, widget: widget, display: display).maxX - 10,
            756, "the text ends at the point")
    }

    func testAWidgetStaysOnItsDisplayWhereverItIsPutAndWhereverTheDisplayIs() {
        var widget = DesktopWidget(kind: .time)
        let size = NSSize(width: 300, height: 120)
        let left = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0)] {
            widget.x = x
            widget.y = y
            for screen in [display, left] {
                let frame = DesktopWidgetRendering.frame(textSize: size, padding: 4, widget: widget, display: screen)
                XCTAssertTrue(screen.contains(frame), "\(x),\(y) on \(screen)")
                XCTAssertEqual(frame.size, NSSize(width: 308, height: 128), "moved, never shrunk")
            }
        }
    }

    func testAWidgetIsNeverTallerThanMostOfItsDisplay() {
        let widget = DesktopWidget(kind: .text)
        let frame = DesktopWidgetRendering.frame(
            textSize: NSSize(width: 400, height: 5000), padding: 4, widget: widget, display: display)
        XCTAssertEqual(frame.height, floor(display.height * DesktopWidgetRendering.heightLimit))
        XCTAssertTrue(display.contains(frame))
    }

    func testTheLargestWidgetNeverMakesADisplayCountAsCovered() throws {
        // A small display with a large menu bar and Dock leaves the smallest working area.
        let screen = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let working = NSRect(x: 0, y: 70, width: 1024, height: 660)
        let probe = try XCTUnwrap(WallpaperCoverageProbes.probeFrame(for: working))
        var widget = DesktopWidget(kind: .time)
        widget.size = DesktopWidget.sizeRange.upperBound
        widget.weight = 900
        widget.showsSeconds = true
        widget.timeFormat = .twelveHour
        let text = DesktopWidgetRendering.attributedText("12:00:00 PM", for: widget)
        let frame = DesktopWidgetRendering.frame(
            textSize: text.size(), padding: DesktopWidgetRendering.padding(for: widget), widget: widget,
            display: screen)
        XCTAssertFalse(frame.contains(probe), "some of the probe always shows beside it")

        var analog = DesktopWidget(kind: .analog)
        analog.size = DesktopWidget.sizeRange.upperBound
        let face = DesktopWidgetRendering.analogFace(
            for: analog, inputs: .init(date: moment, calendar: .current, locale: english))
        let faceFrame = DesktopWidgetRendering.frame(
            textSize: NSSize(width: face.diameter, height: face.diameter),
            padding: DesktopWidgetRendering.padding(for: analog), widget: analog, display: screen)
        XCTAssertFalse(faceFrame.contains(probe), "nor beside the largest clock face")
    }

    // MARK: Time

    func testTheWordsNextChangeAtTheNextSecondMinuteOrMidnightTheyNeed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var clock = DesktopWidget(kind: .time)
        let date = DesktopWidget(kind: .date)
        func next(_ widgets: [DesktopWidget]) -> Date? {
            DesktopWidgetRendering.nextChange(after: moment, widgets: widgets, calendar: calendar)
        }
        XCTAssertNil(next([]))
        XCTAssertEqual(next([date]), Date(timeIntervalSince1970: 1_794_182_400), "midnight")
        XCTAssertEqual(next([date, clock]), Date(timeIntervalSince1970: 1_794_171_960), "21:06")
        clock.showsSeconds = true
        XCTAssertEqual(next([date, clock]), Date(timeIntervalSince1970: 1_794_171_908), "21:05:08")
    }

    // MARK: Keeping them

    func testAWidgetSavedWithFewerFieldsKeepsWhatItHasAndDefaultsTheRest() throws {
        let data = Data(#"[{"id":"a","kind":"date","size":40,"placement":{"all":{}}}]"#.utf8)
        let widgets = try DesktopWidgetStore.decode(data)
        XCTAssertEqual(widgets.count, 1)
        XCTAssertEqual(widgets[0].size, 40)
        XCTAssertEqual(widgets[0].placement, .all)
        XCTAssertEqual(widgets[0].weight, DesktopWidget(kind: .date).weight)
        XCTAssertEqual(widgets[0].dateStyle, .weekdayMonthDay)
        XCTAssertNil(widgets[0].timeZone)
        XCTAssertEqual(widgets[0].calendarSystem, .system)
        XCTAssertEqual(widgets[0].text, "")
        XCTAssertNil(widgets[0].fontFamily)
        XCTAssertEqual(widgets[0].background, .off)
        XCTAssertEqual(widgets[0].outlineWidth, 0)
        XCTAssertTrue(widgets[0].hasShadow)
        XCTAssertEqual(widgets[0].shadowAngle, 180, "an older widget keeps the shadow it had")

        let every = try DesktopWidgetStore.decode(JSONEncoder().encode(DesktopWidget.Kind.allCases.map {
            var widget = DesktopWidget(kind: $0)
            widget.timeZone = "Europe/Paris"
            widget.text = "Line one\nline two"
            return widget
        }))
        XCTAssertEqual(every.map(\.kind), DesktopWidget.Kind.allCases, "every kind is kept")
    }

    func testValuesNoControlCouldChooseAreRefused() {
        for json in [
            #"[{"id":"a","kind":"time","size":2000}]"#,
            #"[{"id":"a","kind":"time","x":1.5}]"#,
            #"[{"id":"a","kind":"time","color":"white"}]"#,
            #"[{"id":"a","kind":"time","weight":450}]"#,
            #"[{"id":"a","kind":"time"},{"id":"a","kind":"date"}]"#,
            #"[{"id":"","kind":"time"}]"#,
            #"[{"id":"a","kind":"weather"}]"#,
            #"[{"id":"a","kind":"time","timeZone":"Mars/Olympus_Mons"}]"#,
            #"[{"id":"a","kind":"countdown","targetDay":"2026-02-30"}]"#,
            #"[{"id":"a","kind":"countdown","targetDay":"20261120"}]"#,
            #"[{"id":"a","kind":"text","text":"a\u0000b"}]"#,
            #"[{"id":"a","kind":"time","outlineWidth":40}]"#,
            #"[{"id":"a","kind":"time","shadowAngle":360}]"#,
            #"[{"id":"a","kind":"time","rotation":270}]"#,
            #"[{"id":"a","kind":"time","glowColor":"red"}]"#,
            ##"[{"id":"a","kind":"time","accentColor":"#12"}]"##,
            #"[{"id":"a","kind":"time","background":"blur"}]"#,
            #"[{"id":"a","kind":"time","fontFamily":"a\nb"}]"#,
            "[{\"id\":\"a\",\"kind\":\"text\",\"text\":\"\(String(repeating: "x", count: 501))\"}]",
        ] {
            XCTAssertThrowsError(try DesktopWidgetStore.decode(Data(json.utf8)), json)
        }
    }

    func testTheStoreKeepsEachChangeAndTellsTheDesktop() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: DesktopWidgetStore.didChangeNotification, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(token) }
        let store = DesktopWidgetStore(defaults: defaults, center: center)

        let clock = try store.add(.time)
        let second = try store.add(.time)
        XCTAssertNotEqual(clock.y, second.y, "a new widget does not land on one already there")
        try store.update(clock.id) {
            $0.size = 5000
            $0.weight = 640
            $0.color = "#12ab9F"
        }
        try store.remove(second.id)
        XCTAssertEqual(posts, 4)

        let reopened = DesktopWidgetStore(defaults: defaults, center: center)
        XCTAssertEqual(reopened.widgets.count, 1)
        XCTAssertEqual(reopened.widgets[0].size, DesktopWidget.sizeRange.upperBound, "a change is kept in range")
        XCTAssertEqual(reopened.widgets[0].weight, 600)
        XCTAssertEqual(reopened.widgets[0].color, "#12ab9F")
        XCTAssertThrowsError(try store.remove(second.id)) { XCTAssertEqual($0 as? DesktopWidgetError, .missing) }

        for _ in 1..<DesktopWidgetStore.limit { try store.add(.date) }
        XCTAssertThrowsError(try store.add(.date)) { XCTAssertEqual($0 as? DesktopWidgetError, .tooMany) }
    }

    func testTheOrderIsTheLayersAndANewOrCopiedWidgetGoesInFront() throws {
        let store = DesktopWidgetStore(defaults: try TemporaryDefaults.make(for: self).defaults, center: NotificationCenter())
        let clock = try store.add(.time)
        let date = try store.add(.date)
        let text = try store.add(.text)
        XCTAssertEqual(store.widgets.map(\.id), [text.id, date.id, clock.id], "the newest in front")

        try store.move(clock.id, to: 0)
        XCTAssertEqual(store.widgets.map(\.id), [clock.id, text.id, date.id])
        try store.move(clock.id, to: 99)
        XCTAssertEqual(store.widgets.map(\.id), [text.id, date.id, clock.id], "past the back stays at the back")
        try store.move(text.id, to: 1, expected: [clock.id, text.id, date.id])
        XCTAssertEqual(
            store.widgets.map(\.id), [text.id, date.id, clock.id], "a move from an order since changed does nothing")
        XCTAssertThrowsError(try store.move("gone", to: 0)) { XCTAssertEqual($0 as? DesktopWidgetError, .missing) }

        try store.update(date.id) { $0.size = 50; $0.text = "Paris" }
        let copy = try store.duplicate(date.id)
        XCTAssertEqual(store.widgets.map(\.id), [text.id, copy.id, date.id, clock.id], "just in front of it")
        XCTAssertNotEqual(copy.id, date.id)
        XCTAssertEqual(copy.size, 50)
        XCTAssertEqual(copy.text, "Paris")
        XCTAssertNotEqual(copy.y, try store.widget(date.id).y, "not right on top of it")
    }

    func testABackupCarriesTheWidgetsAndRefusesBrokenOnes() throws {
        XCTAssertTrue(WallpaperBackupPreferences.allowedKeys.contains(DesktopWidgetStore.storageKey))
        let valid = try JSONEncoder().encode([DesktopWidget(kind: .time)])
        XCTAssertNoThrow(try WallpaperBackupPreferences.validate(valid, forKey: DesktopWidgetStore.storageKey))
        XCTAssertThrowsError(try WallpaperBackupPreferences.validate(
            Data(#"[{"id":"a","kind":"time","opacity":0}]"#.utf8), forKey: DesktopWidgetStore.storageKey))
    }

    func testTheColourWellsColourIsKeptAsSRGBHex() {
        XCTAssertEqual(DesktopWidget.hex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)), "#FF8000")
        XCTAssertNotNil(DesktopWidget.rgb("#00ff7F"))
        XCTAssertNil(DesktopWidget.rgb("#00ff7"))
        XCTAssertNil(DesktopWidget.rgb("00ff7F0"))
        XCTAssertNotNil(DesktopWidget.cssRGB("rgb(38, 46, 86)"))
        XCTAssertNil(DesktopWidget.cssRGB("rgb(300, 0, 0)"))
        XCTAssertNil(DesktopWidget.cssRGB("#FFFFFF"))
    }

    func testNowPlayingAndImageDecodeBackwardCompatiblyAndValidateScopesAndAssets() throws {
        // Older widget records lacking `scope`, Now Playing options, or image fields keep defaults.
        let legacy = Data(#"[{"id":"old","kind":"time"}]"#.utf8)
        let decodedLegacy = try DesktopWidgetStore.decode(legacy)
        XCTAssertEqual(decodedLegacy[0].scope, .everywhere)
        XCTAssertTrue(decodedLegacy[0].showsArtwork)
        XCTAssertTrue(decodedLegacy[0].hidesWhenIdle)
        XCTAssertFalse(decodedLegacy[0].tintsFromArtwork)
        XCTAssertNil(decodedLegacy[0].imageAsset)
        XCTAssertEqual(decodedLegacy[0].imageFit, .fit)
        XCTAssertEqual(decodedLegacy[0].imageCornerRadius, 12)

        // Full round-trip of `.nowPlaying` (wallpaper scope) and `.image` (Space scope).
        var media = DesktopWidget(id: "np-1", kind: .nowPlaying)
        media.showsArtwork = false
        media.hidesWhenIdle = false
        media.tintsFromArtwork = true
        media.scope = .wallpapers(["aurora", "rain"])

        var sticker = DesktopWidget(id: "img-1", kind: .image)
        sticker.imageAsset = .init(assetID: "abcdef0123456789", fileName: "sticker.png", displayName: "cat.png")
        sticker.imageFit = .fill
        sticker.imageCornerRadius = 50
        sticker.scope = .spaces(["default", "space-2"])

        let roundTripped = try DesktopWidgetStore.decode(JSONEncoder().encode([media, sticker]))
        XCTAssertEqual(roundTripped, [media, sticker])

        // Wallpaper matching helper.
        XCTAssertTrue(media.matchesWallpaper("aurora"))
        XCTAssertFalse(media.matchesWallpaper("night"))
        XCTAssertFalse(media.matchesWallpaper(nil))
        XCTAssertTrue(sticker.matchesWallpaper(nil))
        XCTAssertEqual(sticker.pinnedSpaceIDs, ["default", "space-2"])
        XCTAssertNil(media.pinnedSpaceIDs)

        // Out-of-range / unsafe image asset or scope values are rejected.
        for bad in [
            #"[{"id":"a","kind":"image","imageCornerRadius":60}]"#,
            #"[{"id":"a","kind":"image","imageAsset":{"assetID":"../bad","fileName":"sticker.png","displayName":"x.png"}}]"#,
            #"[{"id":"a","kind":"image","imageAsset":{"assetID":"abc","fileName":"sub/a.png","displayName":"x.png"}}]"#,
            #"[{"id":"a","kind":"time","scope":{"wallpapers":{"_0":["wp","wp"]}}}]"#,
            #"[{"id":"a","kind":"time","scope":{"spaces":{"_0":[""]}}}]"#,
        ] {
            XCTAssertThrowsError(try DesktopWidgetStore.decode(Data(bad.utf8)), bad)
        }

        // Clamping sanitizes scope duplicates and invalid assets cleanly.
        var dirty = DesktopWidget(kind: .image)
        dirty.imageCornerRadius = 99
        dirty.imageAsset = .init(assetID: "../escape", fileName: "a.png", displayName: "bad.png")
        dirty.scope = .wallpapers(["wp-1", "", "wp-1", "wp-2"])
        let clean = dirty.clamped()
        XCTAssertEqual(clean.imageCornerRadius, DesktopWidget.imageCornerRadiusRange.upperBound)
        XCTAssertNil(clean.imageAsset)
        XCTAssertEqual(clean.scope, .wallpapers(["wp-1", "wp-2"]))
        XCTAssertTrue(clean.isValid)
    }

    func testNowPlayingRenderingSupportsIdleCollapseAdaptivePaletteAndZeroTimers() throws {
        let formatters = DesktopWidgetRendering.Formatters()
        var widget = DesktopWidget(kind: .nowPlaying)
        XCTAssertNil(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [widget]),
            "Now Playing never schedules a timer")

        // Live idle with default `hidesWhenIdle == true` collapses to `.empty`.
        let collapsed = DesktopWidgetRendering.content(for: widget, inputs: inputs(), formatters: formatters)
        XCTAssertEqual(collapsed.drawing, .empty)
        let collapsedFrame = DesktopWidgetRendering.frame(for: collapsed, widget: widget, display: display)
        XCTAssertEqual(collapsedFrame.size, NSSize(width: 1, height: 1))

        // With `hidesWhenIdle == false`, idle shows a static fallback card.
        widget.hidesWhenIdle = false
        let idleShown = DesktopWidgetRendering.content(for: widget, inputs: inputs(), formatters: formatters)
        guard case .nowPlaying(let idleCard) = idleShown.drawing else { return XCTFail("expected nowPlaying card") }
        XCTAssertEqual(idleCard.title.string, String(localized: "Nothing playing"))
        XCTAssertFalse(idleCard.showsArtwork)

        // Settings preview renders crisp sample track and artwork even when nothing is playing.
        var previewInputs = inputs()
        previewInputs.isPreview = true
        let previewContent = DesktopWidgetRendering.content(for: widget, inputs: previewInputs, formatters: formatters)
        guard case .nowPlaying(let sampleCard) = previewContent.drawing else { return XCTFail("expected sample card") }
        XCTAssertEqual(sampleCard.title.string, String(localized: "Midnight Echo"))
        XCTAssertEqual(sampleCard.subtitle?.string, String(localized: "Luna Waves"))
        XCTAssertNotNil(sampleCard.artwork)

        // Live playing track with adaptive cover palette tints card plate and text color.
        widget.tintsFromArtwork = true
        widget.fill = .gradient
        let thumb = SystemMediaThumbnail(
            pngBase64DataURL: "",
            primaryColor: "rgb(20, 40, 80)",
            secondaryColor: "rgb(100, 120, 160)",
            tertiaryColor: "rgb(200, 200, 220)",
            textColor: "rgb(250, 250, 255)",
            highContrastColor: "rgb(255, 255, 255)",
            rgba: [20, 40, 80, 255, 20, 40, 80, 255, 20, 40, 80, 255, 20, 40, 80, 255],
            width: 2, height: 2)
        let artwork = DesktopWidgetRendering.MediaSnapshot.artwork(from: thumb, token: 1)
        var liveInputs = inputs()
        liveInputs.media = DesktopWidgetRendering.MediaSnapshot(
            title: "Starlight", artist: "Muse", album: "Black Holes",
            playback: .playing, artwork: artwork,
            primaryColor: thumb.primaryColor, textColor: thumb.textColor)
        let live = DesktopWidgetRendering.content(for: widget, inputs: liveInputs, formatters: formatters)
        guard case .nowPlaying(let liveCard) = live.drawing else { return XCTFail("expected live card") }
        XCTAssertEqual(liveCard.title.string, "Starlight")
        XCTAssertEqual(liveCard.subtitle?.string, "Muse")
        XCTAssertNotNil(liveCard.artwork)
        XCTAssertNil(live.look.gradient, "adaptive tint clears gradient to preserve contrast")
        XCTAssertNotNil(live.look.background, "adaptive tint supplies a tinted card plate")
    }

    func testImageStickerRenderingManagedStoreCleanupAndBackupPreservation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managed = ManagedUserAssetStore(root: root.appendingPathComponent("UserAssets", isDirectory: true))
        let imageStore = DesktopWidgetImageStore(managed: managed)

        // Write a valid 40×20 PNG (2:1 landscape aspect) and import it.
        let pngURL = root.appendingPathComponent("banner.png")
        try Self.writeTestPNG(to: pngURL, width: 40, height: 20)
        let asset = try imageStore.importImage(from: pngURL)
        XCTAssertEqual(asset.displayName, "banner.png")
        XCTAssertEqual(asset.fileName, "sticker.png")
        XCTAssertTrue(asset.isValid)
        XCTAssertNotNil(imageStore.url(for: asset))

        // Re-importing identical bytes deduplicates to the same asset ID.
        let secondCopy = root.appendingPathComponent("duplicate.png")
        try FileManager.default.copyItem(at: pngURL, to: secondCopy)
        let secondAsset = try imageStore.importImage(from: secondCopy)
        XCTAssertEqual(secondAsset.assetID, asset.assetID)

        // Unsupported extensions and corrupt images are rejected.
        let textFile = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: textFile)
        XCTAssertThrowsError(try imageStore.importImage(from: textFile)) {
            XCTAssertEqual($0 as? DesktopWidgetImageError, .unsupportedFormat)
        }
        let corruptPNG = root.appendingPathComponent("corrupt.png")
        try Data("not a png".utf8).write(to: corruptPNG)
        XCTAssertThrowsError(try imageStore.importImage(from: corruptPNG)) {
            XCTAssertEqual($0 as? DesktopWidgetImageError, .unreadableImage)
        }

        // Static rendering: `.fit` preserves 2:1 aspect, `.fill` fills a square, zero timers.
        var widget = DesktopWidget(kind: .image)
        widget.size = 100
        widget.imageAsset = asset
        widget.imageFit = .fit
        widget.imageCornerRadius = 25
        XCTAssertNil(DesktopWidgetRendering.nextChange(after: inputs(), widgets: [widget]))

        var renderInputs = inputs()
        renderInputs.resolveImage = { imageStore.loadImage(for: $0) }
        let fitContent = DesktopWidgetRendering.content(
            for: widget, inputs: renderInputs, formatters: DesktopWidgetRendering.Formatters())
        guard case .image(let fitSticker) = fitContent.drawing else { return XCTFail("expected image sticker") }
        XCTAssertNotNil(fitSticker.image)
        XCTAssertEqual(fitContent.size.width, 200, accuracy: 1)
        XCTAssertEqual(fitContent.size.height, 100, accuracy: 1)
        XCTAssertEqual(fitSticker.cornerRadius, 25, accuracy: 0.5)

        widget.imageFit = .fill
        let fillContent = DesktopWidgetRendering.content(
            for: widget, inputs: renderInputs, formatters: DesktopWidgetRendering.Formatters())
        XCTAssertEqual(fillContent.size.width, 200, accuracy: 1)
        XCTAssertEqual(fillContent.size.height, 200, accuracy: 1)

        // Unconfigured image widget collapses on live desktop and shows a placeholder in Settings preview.
        let emptySticker = DesktopWidget(kind: .image)
        let liveEmpty = DesktopWidgetRendering.content(
            for: emptySticker, inputs: renderInputs, formatters: DesktopWidgetRendering.Formatters())
        XCTAssertEqual(liveEmpty.drawing, .empty)
        renderInputs.isPreview = true
        let previewEmpty = DesktopWidgetRendering.content(
            for: emptySticker, inputs: renderInputs, formatters: DesktopWidgetRendering.Formatters())
        guard case .image(let placeholder) = previewEmpty.drawing else { return XCTFail("expected placeholder") }
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertNil(placeholder.image)

        // Managed sticker assets survive `.wmbackup` export and validation cleanly.
        let backupURL = root.deletingLastPathComponent()
            .appendingPathComponent("widget-backup-\(UUID().uuidString).wmbackup")
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let widgetData = try JSONEncoder().encode([widget])
        defaults.set(widgetData, forKey: DesktopWidgetStore.storageKey)
        let backupService = WallpaperBackupService(supportRoot: root)
        let prefs = WallpaperBackupPreferences(values: [
            DesktopWidgetStore.storageKey: try WallpaperBackupPreferences.encode(widgetData),
        ])
        try backupService.export(to: backupURL, includeLibrary: false, preferences: prefs)
        let preview = try backupService.preview(package: backupURL, preferences: WallpaperBackupPreferences(values: [:]))
        XCTAssertGreaterThan(preview.byteCount, 0)

        // Pruning removes unreferenced sticker assets from manifest and disk.
        imageStore.pruneUnused(keeping: [asset.assetID])
        XCTAssertNotNil(imageStore.url(for: asset), "live sticker is kept")
        imageStore.pruneUnused(keeping: [])
        XCTAssertNil(imageStore.url(for: asset), "unused sticker is reclaimed")
    }

    private static func writeTestPNG(to url: URL, width: Int, height: Int) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("CGContext unavailable") }
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.6, 0.9, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
