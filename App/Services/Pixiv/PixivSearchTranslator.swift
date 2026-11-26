import Foundation
import NaturalLanguage
import Observation

/// A pixiv search typed in another language, and the Japanese tags pixiv was searched with instead.
/// Display-only beyond the search itself: nothing stores it.
struct PixivSearchTranslation: Hashable, Sendable {
    /// What the person typed, trimmed.
    let original: String
    /// The translation into Japanese that pixiv is searched with.
    let japanese: String
    /// The BCP-47 language tag the original was read as (e.g. `en`, `zh-Hans`, `zh-Hant`, `ko`, `pt-BR`).
    let language: String
}

/// Source-language detection specifically for translating non-Japanese pixiv queries into Japanese.
///
/// Pixiv tags are predominantly Japanese (`ja`). Anything that already contains Hiragana or
/// Katakana, or reads cleanly as Japanese kanji, is returned as `nil` so it goes to pixiv untouched.
enum PixivSearchLanguage {
    /// Minimum Latin letters required before a Latin-script query is translated into Japanese.
    static let minimumLatinLetters = 2
    /// Confidence required to treat a Latin-script query as Portuguese when the app is in Portuguese.
    static let portugueseConfidence = 0.8
    /// Confidence at which Han-only text (no kana) is treated as already Japanese.
    static let kanjiJapaneseConfidence = 0.7

    /// Detects the non-Japanese source language tag of `text`, or returns `nil` when `text` is
    /// empty, a pixiv link/id, already contains Japanese Kana, reads as Japanese, or has no letters.
    static func detectSource(_ text: String, app: AppLanguage) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= PixivSearchTranslator.maximumLength,
            PixivLink.illustID(in: trimmed) == nil, !trimmed.contains("://")
        else { return nil }

        var han = ""
        var hasKana = false
        var hasHangul = false
        var latinLetters = 0
        var otherLetters = 0
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                hasKana = true
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
                hasHangul = true
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
                han.unicodeScalars.append(scalar)
            default:
                guard scalar.properties.isAlphabetic else { continue }
                if scalar.value <= 0x024F || (0x1E00...0x1EFF).contains(scalar.value) {
                    latinLetters += 1
                } else {
                    otherLetters += 1
                }
            }
        }

        // Anything containing Hiragana or Katakana is already Japanese.
        if hasKana { return nil }
        if hasHangul { return "ko" }
        if !han.isEmpty {
            // A Japanese-interface user typing kanji-only text is searching Japanese tags directly.
            if app.tag == "ja" { return nil }
            let readings = hypotheses(han, among: [.japanese, .simplifiedChinese, .traditionalChinese])
            if (readings[.japanese] ?? 0) >= kanjiJapaneseConfidence { return nil }
            let simplified = han.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? han
            return simplified == han ? "zh-Hans" : "zh-Hant"
        }
        guard otherLetters == 0, latinLetters >= minimumLatinLetters else { return nil }
        if app.tag == "pt-BR" {
            let portuguese = hypotheses(trimmed, among: [.english, .portuguese])[.portuguese] ?? 0
            if portuguese >= portugueseConfidence { return "pt-BR" }
        }
        return "en"
    }

    private static func hypotheses(_ text: String, among languages: [NLLanguage]) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: languages.count)
    }
}

/// Translates non-Japanese pixiv tag searches into Japanese (`ja`) on this Mac before sending them
/// to pixiv's tag search endpoint.
///
/// Dedicated to pixiv and completely independent of `WorkshopSearchTranslator` (which targets English):
/// - Target language is always Japanese (`Locale.Language(identifier: "ja")`).
/// - Skips empty queries, queries that already contain Japanese Kana or read as Japanese, pixiv URLs
///   and bare illustration ids.
/// - Only runs on-device translations for already-installed macOS Translation language packs so
///   typing never interrupts search with a system download sheet.
/// - Accepts an injectable `translate` closure so unit tests run deterministically with zero network
///   calls or model downloads.
@MainActor
@Observable
final class PixivSearchTranslator {
    /// Persisted toggle in `UserDefaults`. When absent, defaults to `true` unless the app language
    /// is Japanese (`ja`).
    nonisolated static let enabledKey = "WallpaperMachine.translatesPixivSearches"
    /// Maximum cached translations (LRU).
    static let cacheLimit = 100
    /// Longer text is searched as typed: a tag query is a few words, not a passage.
    nonisolated static let maximumLength = 256
    /// Target language for pixiv tag searches.
    nonisolated static let japanese = Locale.Language(identifier: "ja")

    /// Injectable translation closure for deterministic testing without system language packs.
    typealias TranslateClosure = @MainActor (
        _ text: String, _ source: Locale.Language, _ target: Locale.Language
    ) async throws -> String

    private(set) var isEnabled: Bool
    private var pendingTranslations = 0
    /// True while a translation request is in flight.
    var isTranslating: Bool { pendingTranslations > 0 }

    @ObservationIgnored private let backend: (any OnDeviceTranslating)?
    @ObservationIgnored private let translateClosure: TranslateClosure?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appLanguage: @MainActor () -> AppLanguage
    /// Cached answers keyed by `<sourceTag>\u{1F}<typed>`; `.some(nil)` caches an unchanged result.
    @ObservationIgnored private var answers: [String: String?] = [:]
    @ObservationIgnored private var answerOrder: [String] = []

    /// Creates a pixiv Japanese-tag translator.
    /// - Parameters:
    ///   - defaults: Preference store for `enabledKey`.
    ///   - backend: On-device macOS Translation adapter (used when `translate` is nil).
    ///   - translate: Optional deterministic closure replacing `backend` in unit tests.
    ///   - appLanguage: Current app interface language.
    init(
        defaults: UserDefaults = ClientPreferences.defaults,
        backend: (any OnDeviceTranslating)? = nil,
        translate: TranslateClosure? = nil,
        appLanguage: @escaping @MainActor () -> AppLanguage = { AppLanguageStore.shared.effective }
    ) {
        self.defaults = defaults
        self.translateClosure = translate
        self.backend = translate == nil ? (backend ?? SystemTranslation()) : nil
        self.appLanguage = appLanguage
        if let stored = defaults.object(forKey: Self.enabledKey) as? Bool {
            isEnabled = stored
        } else {
            isEnabled = appLanguage().tag != "ja"
        }
    }

    /// Whether `text` is a non-Japanese query eligible for translation (regardless of whether the
    /// user currently has translation enabled).
    static func isTranslatable(_ text: String, app: AppLanguage) -> Bool {
        PixivSearchLanguage.detectSource(text, app: app) != nil
    }

    /// Translates `text` into Japanese for pixiv tag search, or returns `nil` to search as typed.
    func translation(for text: String) async -> PixivSearchTranslation? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !typed.isEmpty, typed.count <= Self.maximumLength,
            PixivLink.illustID(in: typed) == nil, !typed.contains("://"),
            let sourceTag = PixivSearchLanguage.detectSource(typed, app: appLanguage())
        else { return nil }

        let key = "\(sourceTag)\u{1F}\(typed)"
        if let cached = answers[key] {
            remember(key, cached)
            return cached.map { PixivSearchTranslation(original: typed, japanese: $0, language: sourceTag) }
        }

        let source = Locale.Language(identifier: sourceTag)
        pendingTranslations += 1
        defer { pendingTranslations -= 1 }

        let raw: String
        do {
            if let translateClosure {
                raw = try await translateClosure(typed, source, Self.japanese)
            } else if let backend {
                guard await backend.availability(from: source, to: Self.japanese) == .installed else {
                    return nil
                }
                try Task.checkCancellation()
                raw = try await backend.translate(typed, from: source, to: Self.japanese)
            } else {
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.warn("Translating a pixiv search from \(sourceTag) to ja failed: \(error.localizedDescription)")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let japanese = Self.searchWords(raw, for: typed)
        remember(key, japanese)
        return japanese.map { PixivSearchTranslation(original: typed, japanese: $0, language: sourceTag) }
    }

    /// Cleans a translated phrase for pixiv tag search: trims whitespace, drops a trailing full
    /// stop added by the translator, and returns `nil` when empty or identical to `original`.
    static func searchWords(_ translation: String, for original: String) -> String? {
        var words = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.hasSuffix("。"), !original.hasSuffix("。"), !original.hasSuffix(".") {
            words = String(words.dropLast()).trimmingCharacters(in: .whitespaces)
        } else if words.hasSuffix("."), !original.hasSuffix("."), !original.hasSuffix("。") {
            words = String(words.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !words.isEmpty,
            words.compare(original, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        else { return nil }
        return words
    }

    /// Persists whether pixiv searches are translated into Japanese.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        isEnabled = on
    }

    /// Restores the default preference (enabled unless the app language is Japanese).
    func resetPreference() {
        defaults.removeObject(forKey: Self.enabledKey)
        isEnabled = appLanguage().tag != "ja"
    }

    private func remember(_ key: String, _ answer: String?) {
        answers[key] = .some(answer)
        answerOrder.removeAll { $0 == key }
        answerOrder.append(key)
        while answerOrder.count > Self.cacheLimit {
            answers[answerOrder.removeFirst()] = nil
        }
    }
}
