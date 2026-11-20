import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The download dialog's text inputs keep macOS restricted to Roman keyboard layouts while focused
/// (so CJK input methods such as WeChat Input Method switch away on focus and restore when focus
/// leaves) and behave cleanly with editing, submission, clearing and programmatic focus.
@MainActor
final class DownloadDialogInputTests: MediaPanelTestCase {
  private func hostView<Content: View>(
    _ view: Content, size: NSSize = NSSize(width: 460, height: 640)
  ) -> (window: NSWindow, container: NSView, hosting: NSHostingView<AnyView>) {
    let hosting = NSHostingView(rootView: AnyView(view))
    hosting.sceneBridgingOptions = []
    hosting.frame = NSRect(origin: .zero, size: size)
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.addSubview(hosting)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    hosting.layoutSubtreeIfNeeded()
    return (window, container, hosting)
  }

  private func hostDialog(
    controller: PanelController, session: DownloadsModel.Session? = nil,
    resolution: DownloadDialogResolution? = nil
  ) -> (window: NSWindow, container: NSView, hosting: NSHostingView<AnyView>) {
    hostView(
      DownloadDialogView(session: session, resolution: resolution)
        .environment(controller)
        .environment(\.panelImages, controller.images)
        .environment(\.panelIsVisible, true)
        .panelTheme(theme: controller.theme, locale: PanelLocale.shared)
        .frame(width: 460))
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    func walk(_ current: NSView) {
      if let field = current as? NSTextField, field.isEditable { found.append(field) }
      current.subviews.forEach(walk)
    }
    walk(view)
    return found
  }

  private func resolve(
    request: DownloadRequestRow? = nil, own: DownloadRow? = nil
  ) throws -> DownloadDialogResolution {
    try XCTUnwrap(
      DownloadDialogResolution.resolve(
        target: "222", request: request, own: own, sceneAssets: nil, currentStage: nil,
        handoffTarget: nil))
  }

  /// Focusing the Steam password field restricts its input context to Roman keyboard layouts (as
  /// native `NSSecureTextField` does), and moving focus to an unrestricted field restores normal
  /// input sources.
  func testSteamPasswordFieldRestrictsInputSourcesToRomanAndRestoresOnBlur() async throws {
    let panel = try makeDiscoverPanel()
    let session = DownloadsModel.Session(target: "222", account: "bobby", remembersSession: true)
    let resolved = try resolve(
      own: DownloadRow(
        id: "222", title: "Rainy Window", account: "bobby", isPending: true, prompt: .password))
    let (window, container, hosting) = hostDialog(
      controller: panel.controller, session: session, resolution: resolved)
    defer {
      window.makeFirstResponder(nil)
      window.contentView = nil
      window.close()
    }
    try await Task.sleep(for: .milliseconds(100))
    hosting.layoutSubtreeIfNeeded()

    let secureField = try XCTUnwrap(
      textFields(in: hosting).first(where: { $0 is NSSecureTextField }) as? NSSecureTextField,
      "the password stage must render a secure text field")
    XCTAssertEqual(secureField.contentType, .password)
    let cell = try XCTUnwrap(secureField.cell as? NSTextFieldCell)
    XCTAssertEqual(
      cell.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier],
      "the password field's cell must restrict input sources to Roman layouts")

    XCTAssertTrue(window.makeFirstResponder(secureField))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertEqual(
      editor.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier],
      "the active secure field editor must restrict input sources to Roman layouts")
    XCTAssertEqual(
      editor.inputContext?.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier],
      "the active text input context must exclude non-Roman IMEs while the password field has focus")

    // Moving focus to an ordinary field in the same window restores unrestricted input sources.
    let ordinary = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    container.addSubview(ordinary)
    defer { ordinary.removeFromSuperview() }
    XCTAssertTrue(window.makeFirstResponder(ordinary))
    let ordinaryEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertNil(ordinaryEditor.allowedInputSourceLocales)
    XCTAssertNil(ordinaryEditor.inputContext?.allowedInputSourceLocales)
  }

  /// Steam Guard codes (ASCII alphabet containing `V`) and Steam account login names also restrict
  /// keyboard input sources to Roman layouts while focused.
  func testSteamGuardCodeAndAccountFieldsRestrictInputSourcesToRoman() async throws {
    let panel = try makeDiscoverPanel()
    let cases: [(name: String, contentType: NSTextContentType, resolution: DownloadDialogResolution)] = [
      (
        "Steam Guard code", .oneTimeCode,
        try resolve(
          own: DownloadRow(
            id: "222", title: "Rainy Window", account: "bobby", isPending: true,
            prompt: .guardCode, challenge: .emailCode))
      ),
      (
        "Steam account name", .username,
        try resolve(request: DownloadRequestRow(id: "222", title: "Rainy Window", stage: .account))
      ),
    ]
    for (name, expectedContentType, resolved) in cases {
      let session = DownloadsModel.Session(target: "222", account: "bobby", remembersSession: true)
      let (window, _, hosting) = hostDialog(
        controller: panel.controller, session: session, resolution: resolved)
      defer {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
      }
      try await Task.sleep(for: .milliseconds(100))
      hosting.layoutSubtreeIfNeeded()

      let field = try XCTUnwrap(
        textFields(in: hosting).first(where: { !($0 is NSSecureTextField) }),
        "\(name): stage must render an editable non-secure text field")
      XCTAssertEqual(field.contentType, expectedContentType, name)
      let cell = try XCTUnwrap(field.cell as? NSTextFieldCell)
      XCTAssertEqual(
        cell.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier],
        "\(name): cell must restrict input sources to Roman layouts")
      XCTAssertTrue(window.makeFirstResponder(field), name)
      let editor = try XCTUnwrap(window.firstResponder as? NSTextView, name)
      XCTAssertEqual(
        editor.inputContext?.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier],
        "\(name): active input context must exclude non-Roman IMEs")
    }
  }

  /// When a real download job asks for a Steam password, `DownloadDialogView` moves focus straight
  /// into the Roman-restricted secure field and clears the typed secret on Return.
  func testDownloadDialogAutomaticallyFocusesPasswordFieldInRomanModeAndClearsOnSubmit()
    async throws
  {
    try await withPanel { panel in
      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil(timeout: 15) { panel.workshop.steamCMDSetup.selectedRuntime != nil }
      let wanted = WorkshopItem(
        id: "222", title: "Local video", creator: "Fixture", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0)
      panel.workshop.selectedItem = wanted
      panel.workshop.username = "localtest"
      panel.controller.remembersSession = false
      panel.show()
      let downloads = panel.controller.downloads
      downloads.start()
      defer { downloads.stop() }

      try await panel.controller.requestDownload(item: wanted)
      try await panel.waitUntil(timeout: 15) {
        downloads.resolution?.stage == .auth && downloads.resolution?.job?.prompt == .password
      }

      let (window, _, hosting) = hostDialog(controller: panel.controller)
      defer {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
      }
      try await panel.waitUntil(timeout: 5) {
        hosting.layoutSubtreeIfNeeded()
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return editor.delegate is NSSecureTextField
      }

      let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
      let secureField = try XCTUnwrap(editor.delegate as? NSSecureTextField)
      XCTAssertEqual(
        editor.inputContext?.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier],
        "auto-focused password field must immediately restrict input sources to Roman layouts")

      editor.string = "secret-v-pass"
      NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: secureField)
      let delegate = try XCTUnwrap(secureField.delegate)
      XCTAssertTrue(
        delegate.control?(
          secureField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
          ?? false)
      try await panel.waitUntil(timeout: 5) {
        hosting.layoutSubtreeIfNeeded()
        return secureField.stringValue.isEmpty
      }
    }
  }

  func testRomanTextFieldSyncsEditsSubmitsOnReturnClearsAndRespectsFocusRequests() async throws {
    let state = FieldHarnessState()
    state.focusRequest = 1
    let (window, container, hosting) = hostView(
      FieldHarnessView(state: state), size: NSSize(width: 360, height: 120))
    defer {
      window.makeFirstResponder(nil)
      window.contentView = nil
      window.close()
    }
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()

    let field = try XCTUnwrap(textFields(in: hosting).first as? NSSecureTextField)
    XCTAssertEqual(field.accessibilityLabel(), "Steam password")
    let initialEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertTrue(
      initialEditor.delegate === field, "a positive focusRequest must focus the field once attached")

    // Moving focus away and triggering an unrelated redraw must not steal focus back.
    let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
    container.addSubview(other)
    defer { other.removeFromSuperview() }
    XCTAssertTrue(window.makeFirstResponder(other))
    state.label = "Steam 密码"
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(field.accessibilityLabel(), "Steam 密码")
    XCTAssertTrue(
      (window.firstResponder as? NSTextView)?.delegate === other,
      "an unchanged focusRequest must not steal focus back after the user moves it")

    // Incrementing focusRequest focuses the field again.
    state.focusRequest = 2
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertTrue(editor.delegate === field)

    // Typing updates the SwiftUI binding and Return submits without leaking Escape.
    editor.string = "p@ssv0rd"
    NotificationCenter.default.post(
      name: NSControl.textDidChangeNotification, object: field)
    XCTAssertEqual(state.text, "p@ssv0rd")

    let delegate = try XCTUnwrap(field.delegate)
    XCTAssertFalse(
      delegate.control?(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        ?? true,
      "Escape must stay unhandled so the dialog's cancel action can dismiss the sheet")
    XCTAssertTrue(
      delegate.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        ?? false)
    XCTAssertEqual(state.submitted, ["p@ssv0rd"])

    // Clearing the binding clears both the control and its active field editor.
    state.text = ""
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(field.stringValue, "")
    XCTAssertEqual(editor.string, "")

    // Disabling through SwiftUI disables the AppKit control.
    state.isDisabled = true
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()
    XCTAssertFalse(field.isEnabled)
  }

  func testRomanTextFieldDisablesAutocorrectionWhileEditingAndRestoresSharedEditorOptions() async throws {
    let state = FieldHarnessState()
    state.isSecure = false
    state.label = "Steam Guard code"
    let (window, _, hosting) = hostView(
      FieldHarnessView(state: state), size: NSSize(width: 360, height: 120))
    defer {
      window.makeFirstResponder(nil)
      window.contentView = nil
      window.close()
    }
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()

    let field = try XCTUnwrap(textFields(in: hosting).first)
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.isAutomaticSpellingCorrectionEnabled = true
    editor.isAutomaticTextReplacementEnabled = true
    editor.isAutomaticTextCompletionEnabled = true
    editor.isAutomaticQuoteSubstitutionEnabled = true
    editor.isAutomaticDashSubstitutionEnabled = true

    let delegate = try XCTUnwrap(field.delegate)
    XCTAssertTrue(delegate.control?(field, textShouldBeginEditing: editor) ?? false)
    XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
    XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
    XCTAssertFalse(editor.isAutomaticTextCompletionEnabled)
    XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
    XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)

    let endNote = Notification(
      name: NSControl.textDidEndEditingNotification, object: field,
      userInfo: ["NSFieldEditor": editor])
    delegate.controlTextDidEndEditing?(endNote)
    XCTAssertTrue(editor.isAutomaticSpellingCorrectionEnabled)
    XCTAssertTrue(editor.isAutomaticTextReplacementEnabled)
    XCTAssertTrue(editor.isAutomaticTextCompletionEnabled)
    XCTAssertTrue(editor.isAutomaticQuoteSubstitutionEnabled)
    XCTAssertTrue(editor.isAutomaticDashSubstitutionEnabled)
  }

  func testSwitchingRomanTextFieldFromSecureToPlainReplacesViewAndClearsSecret() async throws {
    let state = FieldHarnessState()
    state.isSecure = true
    state.text = "top-secret-v"
    let (window, _, hosting) = hostView(
      FieldHarnessView(state: state), size: NSSize(width: 360, height: 120))
    defer {
      window.makeFirstResponder(nil)
      window.contentView = nil
      window.close()
    }
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()

    let secureField = try XCTUnwrap(textFields(in: hosting).first as? NSSecureTextField)
    XCTAssertEqual(secureField.stringValue, "top-secret-v")

    state.isSecure = false
    state.text = ""
    try await Task.sleep(for: .milliseconds(50))
    hosting.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      secureField.stringValue, "",
      "dismantling the secure field must clear its secret stringValue")
    let plainField = try XCTUnwrap(textFields(in: hosting).first)
    XCTAssertFalse(plainField is NSSecureTextField)
    let cell = try XCTUnwrap(plainField.cell as? NSTextFieldCell)
    XCTAssertEqual(cell.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier])
  }
}

@MainActor
@Observable
private final class FieldHarnessState {
  var text = ""
  var isSecure = true
  var isDisabled = false
  var label = "Steam password"
  var focusRequest = 0
  var submitted: [String] = []
}

private struct FieldHarnessView: View {
  var state: FieldHarnessState

  var body: some View {
    RomanTextField(
      text: Binding(get: { state.text }, set: { state.text = $0 }),
      isSecure: state.isSecure,
      contentType: state.isSecure ? .password : .oneTimeCode,
      accessibilityLabel: state.label,
      focusRequest: state.focusRequest
    ) {
      state.submitted.append(state.text)
    }
    .disabled(state.isDisabled)
    .frame(width: 320)
  }
}
