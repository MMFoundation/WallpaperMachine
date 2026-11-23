import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The numbers a person types into the Displays card: parsed in the panel's locale, never read as 0
/// from an empty field, and held to the range the display offers.
@MainActor
final class InspectorInputTests: XCTestCase {
  func testAScaleFactorIsAWholeFiniteDecimalAboveZeroInTheLocalesOwnNotation() {
    let english = Locale(identifier: "en_US")
    let german = Locale(identifier: "de_DE")
    XCTAssertEqual(ScaleFactorInput.parse("1.34", locale: english), 1.34)
    XCTAssertEqual(ScaleFactorInput.parse(" 2 ", locale: english), 2)
    XCTAssertEqual(ScaleFactorInput.parse("1,34", locale: german), 1.34)
    XCTAssertEqual(ScaleFactorInput.parse("0.5", locale: english), 0.5)
    for refused in ["", "   ", "0", "-1", "1abc", "abc", "1.2.3", "1e3x", "∞", "nan"] {
      XCTAssertNil(ScaleFactorInput.parse(refused, locale: english), "\(refused) is not a scale factor")
    }
  }

  /// The Scale percentage slider shows the scale factor as a whole percentage from 10 to 100 and
  /// asks for the factor of the percentage it settles on. Settling where the factor already puts
  /// the thumb asks for nothing, so a click on a slider held at its top never turns 1.34 into 1.
  func testTheScaleSliderIsTheScaleFactorAsAWholePercentageFromTenToOneHundred() {
    XCTAssertEqual(ScaleSlider.range, 10...100)
    XCTAssertEqual(ScaleSlider.percent(for: 1), 100)
    XCTAssertEqual(ScaleSlider.percent(for: 0.8), 80)
    XCTAssertEqual(ScaleSlider.percent(for: 0.855), 86, "a fraction of a percent sits at the nearest one")
    XCTAssertEqual(ScaleSlider.percent(for: 1.34), 100, "a factor above 1 is the top of the slider")
    XCTAssertEqual(ScaleSlider.percent(for: 0.02), 10, "and one below a tenth is the bottom")
    XCTAssertEqual(ScaleSlider.percent(for: .nan), 100)

    XCTAssertEqual(ScaleSlider.factor(for: 80, current: 1), 0.8)
    XCTAssertEqual(ScaleSlider.factor(for: 79.6, current: 1), 0.8, "a drag settles on a whole percentage")
    XCTAssertEqual(ScaleSlider.factor(for: 100, current: 0.5), 1)
    XCTAssertEqual(ScaleSlider.factor(for: 99, current: 1.34), 0.99)
    XCTAssertEqual(ScaleSlider.factor(for: 4, current: 1), 0.1, "never below the range")
    XCTAssertNil(ScaleSlider.factor(for: 100, current: 1.34), "the thumb did not leave the top")
    XCTAssertNil(ScaleSlider.factor(for: 80, current: 0.8))
    XCTAssertNil(ScaleSlider.factor(for: 86, current: 0.855), "nor does it round a typed factor")
    for percent in stride(from: 10.0, through: 100, by: 1) {
      let factor = ScaleSlider.factor(for: percent, current: percent == 100 ? 0.5 : 1)
      XCTAssertEqual(factor.map(ScaleSlider.percent(for:)), percent, "\(percent)% comes back as itself")
    }
  }

  func testAFrameRateIsAWholeNumberHeldToTheDisplaysRangeAndAnEmptyFieldIsNothing() {
    XCTAssertEqual(FrameRateInput.parse("30", maximum: 60), 30)
    XCTAssertEqual(FrameRateInput.parse(" 45 ", maximum: 60), 45)
    XCTAssertEqual(FrameRateInput.parse("240", maximum: 60), 60, "held to the display's own maximum")
    XCTAssertEqual(FrameRateInput.parse("0", maximum: 60), 1, "a typed zero is the lowest rate, never sent as 0")
    XCTAssertNil(FrameRateInput.parse("", maximum: 60), "an empty field never becomes a value")
    XCTAssertNil(FrameRateInput.parse("3.5", maximum: 60))
    XCTAssertNil(FrameRateInput.parse("-5", maximum: 60))
    XCTAssertNil(FrameRateInput.parse("fast", maximum: 60))
    XCTAssertEqual(FrameRateInput.clamp(500, maximum: 0), 1, "a maximum the display did not report is never read as less than 1")
    XCTAssertEqual(FrameRateInput.clamp(-4, maximum: 30), 1)
  }

  /// Two clicks of the stepper on 30 before the first save lands ask for 31 and then 32, not 31
  /// twice; once nothing is on its way the row shows the renderer's value again.
  func testAStepMovesFromTheRateLastAskedForUntilItsSaveHasFinished() {
    var draft = FrameRateDraft()
    XCTAssertEqual(draft.shown(saved: 30), 30)
    draft.ask(draft.shown(saved: 30) + 1)
    draft.ask(draft.shown(saved: 30) + 1)
    XCTAssertEqual(draft.shown(saved: 30), 32, "the second step moves on from the first")
    draft.answered(31)
    XCTAssertTrue(draft.isWaiting, "an older save finishing leaves the newer one waiting")
    XCTAssertEqual(draft.shown(saved: 31), 32)
    draft.answered(32)
    XCTAssertFalse(draft.isWaiting)
    XCTAssertEqual(draft.shown(saved: 32), 32)

    draft.ask(33)
    draft.answered(33)
    XCTAssertEqual(draft.shown(saved: 32), 32, "a refused save shows the renderer's value again")
  }

  /// A switch, choice or colour stays beside its label while the label fits on one line; otherwise
  /// it moves under it. The hidden Modified mark counts, so changing the value never moves it.
  func testASmallControlMovesUnderItsLabelOnlyWhenTheLabelWouldNotFitBesideIt() {
    func beside(label: CGFloat, marks: CGFloat = 22, control: CGFloat = 40, width: CGFloat) -> Bool {
      PropertyTopLineLayout.fitsBeside(
        label: label, marks: marks, control: control, spacing: 8, width: width)
    }
    XCTAssertTrue(beside(label: 90, marks: 22 + 70, width: 244), "90 + 8 + 92 + 8 + 40 = 238")
    XCTAssertFalse(beside(label: 90, marks: 22 + 70, width: 204), "the narrowest column")
    XCTAssertFalse(
      beside(label: 300, marks: 22, control: 120, width: 244),
      "a long author label above a choice, rather than broken beside it")
    XCTAssertTrue(beside(label: 300, control: 0, width: 100), "nothing beside the label to move")
    XCTAssertTrue(beside(label: 100, marks: 0, control: 40, width: 148), "no marks, one gap")
    XCTAssertFalse(beside(label: 100, marks: 0, control: 40, width: 147))
  }

  /// A row counts the same room for its mark whichever it shows, Modified, Not applied or none, so
  /// an edit, an Apply or a Revert never moves its control from one line to the other. That holds
  /// only while the widths the row counts are the pills' drawn widths, in every shipped language.
  func testSwitchingBetweenModifiedNotAppliedAndNoMarkNeverMovesTheControl() {
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
    for language in AppLanguage.supported.map(\.tag) {
      let languages = AppLanguageStore(
        defaults: TemporaryDefaults.makeForCurrentTest().defaults, systemLanguages: [language])
      PanelLocale.shared.bind(to: languages)
      let slot = ModifiedMark.slotWidth()
      XCTAssertEqual(ModifiedMark.reserve(for: nil), slot, "\(language): no mark keeps the whole slot")
      for kind in [ModifiedMark.Kind.modified, .notApplied] {
        let hosting = NSHostingView(
          rootView: ModifiedMark(kind: kind).environment(\.locale, PanelLocale.shared.locale))
        XCTAssertEqual(
          hosting.fittingSize.width, ModifiedMark.width(kind), accuracy: 1,
          "\(language) \(kind): the width a row counts is the pill it draws")
        XCTAssertGreaterThanOrEqual(ModifiedMark.reserve(for: kind), 0, "\(language) \(kind)")
        XCTAssertEqual(
          ModifiedMark.width(kind) + ModifiedMark.reserve(for: kind), slot, "\(language) \(kind)")
      }
    }
  }
}
