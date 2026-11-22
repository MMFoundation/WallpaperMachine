import XCTest
@testable import WallpaperMachine

final class PasswordInputSourceSwitcherTests: XCTestCase {
  func testPasswordFocusSelectsASCIILayoutAndBlurRestoresPreviousSource() {
    let ime = PasswordInputSource(identifier: "ime", isKeyboardLayout: false)
    let ascii = PasswordInputSource(identifier: "ascii", isKeyboardLayout: true)
    let harness = Harness(current: ime, ascii: ascii)
    let switcher = harness.makeSwitcher()

    switcher.focus()
    switcher.focus()
    XCTAssertEqual(harness.current, ascii)
    XCTAssertEqual(harness.selections, [ascii.identifier])

    switcher.blur()
    XCTAssertEqual(harness.current, ime)
    XCTAssertEqual(harness.selections, [ascii.identifier, ime.identifier])
  }

  func testKeyboardLayoutDoesNotChange() {
    let current = PasswordInputSource(identifier: "dvorak", isKeyboardLayout: true)
    let harness = Harness(current: current, ascii: PasswordInputSource(identifier: "ascii", isKeyboardLayout: true))
    let switcher = harness.makeSwitcher()

    switcher.focus()
    switcher.blur()

    XCTAssertEqual(harness.current, current)
    XCTAssertTrue(harness.selections.isEmpty)
  }

  func testMissingASCIILayoutLeavesCurrentSourceUnchanged() {
    let ime = PasswordInputSource(identifier: "ime", isKeyboardLayout: false)
    let harness = Harness(current: ime, ascii: nil)
    let switcher = harness.makeSwitcher()

    switcher.focus()
    switcher.blur()

    XCTAssertEqual(harness.current, ime)
    XCTAssertTrue(harness.selections.isEmpty)
  }

  func testFailedSelectionDoesNotAttemptRestoration() {
    let ime = PasswordInputSource(identifier: "ime", isKeyboardLayout: false)
    let ascii = PasswordInputSource(identifier: "ascii", isKeyboardLayout: true)
    let harness = Harness(current: ime, ascii: ascii, selectionSucceeds: false)
    let switcher = harness.makeSwitcher()

    switcher.focus()
    switcher.blur()

    XCTAssertEqual(harness.current, ime)
    XCTAssertEqual(harness.selections, [ascii.identifier])
  }

  func testRefocusAfterBlurSelectsTheLayoutAgain() {
    let ime = PasswordInputSource(identifier: "ime", isKeyboardLayout: false)
    let ascii = PasswordInputSource(identifier: "ascii", isKeyboardLayout: true)
    let harness = Harness(current: ime, ascii: ascii)
    let switcher = harness.makeSwitcher()

    switcher.focus()
    switcher.blur()
    switcher.focus()

    XCTAssertEqual(harness.current, ascii)
    XCTAssertEqual(harness.selections, [ascii.identifier, ime.identifier, ascii.identifier])
  }

  func testBlurDoesNotOverrideInputSourceChangedWhileFocused() {
    let ime = PasswordInputSource(identifier: "ime", isKeyboardLayout: false)
    let ascii = PasswordInputSource(identifier: "ascii", isKeyboardLayout: true)
    let manuallySelected = PasswordInputSource(identifier: "another", isKeyboardLayout: true)
    let harness = Harness(current: ime, ascii: ascii)
    let switcher = harness.makeSwitcher()

    switcher.focus()
    harness.current = manuallySelected
    switcher.blur()

    XCTAssertEqual(harness.current, manuallySelected)
    XCTAssertEqual(harness.selections, [ascii.identifier])
  }

  private final class Harness {
    let initial: PasswordInputSource?
    var current: PasswordInputSource?
    let ascii: PasswordInputSource?
    let selectionSucceeds: Bool
    var selections: [String] = []

    init(current: PasswordInputSource?, ascii: PasswordInputSource?, selectionSucceeds: Bool = true) {
      initial = current
      self.current = current
      self.ascii = ascii
      self.selectionSucceeds = selectionSucceeds
    }

    func makeSwitcher() -> PasswordInputSourceSwitcher {
      PasswordInputSourceSwitcher(
        currentSource: { self.current },
        asciiKeyboardLayout: { self.ascii },
        selectSource: { identifier in
          self.selections.append(identifier)
          guard self.selectionSucceeds else { return false }
          self.current = identifier == self.ascii?.identifier ? self.ascii : self.initial
          return true
        })
    }
  }
}
