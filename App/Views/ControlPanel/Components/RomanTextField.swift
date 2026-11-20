import AppKit
import SwiftUI

/// A single-line text or password field whose input context accepts only Roman keyboard layouts
/// (`NSAllRomanInputSourcesLocaleIdentifier`).
///
/// SwiftUI's `SecureField` on macOS clears its `NSSecureTextFieldCell`'s
/// `allowedInputSourceLocales`, leaving CJK input methods active while typing a password (for
/// example WeChat Input Method intercepts `v` for its built-in menu). Wrapping AppKit's
/// `NSSecureTextField` and `NSTextField` keeps the cell restricted to Roman input sources, so
/// macOS switches away from non-Roman input methods on focus and restores them when focus leaves.
struct RomanTextField: View {
  @Binding var text: String
  var isSecure: Bool = false
  var contentType: NSTextContentType?
  var accessibilityLabel: String
  /// Incremented whenever the surrounding view wants this field to take keyboard focus.
  var focusRequest: Int = 0
  var onSubmit: () -> Void

  var body: some View {
    if isSecure {
      AppKitRomanTextField<FocusAwareSecureTextField>(
        text: $text,
        contentType: contentType,
        accessibilityLabel: accessibilityLabel,
        focusRequest: focusRequest,
        onSubmit: onSubmit
      )
    } else {
      AppKitRomanTextField<FocusAwareTextField>(
        text: $text,
        contentType: contentType,
        accessibilityLabel: accessibilityLabel,
        focusRequest: focusRequest,
        onSubmit: onSubmit
      )
    }
  }
}

private protocol WindowObservingTextField: NSTextField {
  var onWindowChange: ((NSTextField) -> Void)? { get set }
}

private final class FocusAwareTextField: NSTextField, WindowObservingTextField {
  var onWindowChange: ((NSTextField) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChange?(self)
  }
}

private final class FocusAwareSecureTextField: NSSecureTextField, WindowObservingTextField {
  var onWindowChange: ((NSTextField) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChange?(self)
  }
}

private struct AppKitRomanTextField<Field: WindowObservingTextField>: NSViewRepresentable {
  @Binding var text: String
  var contentType: NSTextContentType?
  var accessibilityLabel: String
  var focusRequest: Int
  var onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onSubmit: onSubmit)
  }

  func makeNSView(context: Context) -> Field {
    let view = Field()
    view.bezelStyle = .roundedBezel
    view.isBezeled = true
    view.isEditable = true
    view.isSelectable = true
    view.usesSingleLineMode = true
    view.lineBreakMode = .byClipping
    view.isAutomaticTextCompletionEnabled = false
    view.contentType = contentType
    if let cell = view.cell as? NSTextFieldCell {
      cell.isScrollable = true
      cell.wraps = false
      cell.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
    }
    view.delegate = context.coordinator
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setAccessibilityLabel(accessibilityLabel)
    let coordinator = context.coordinator
    view.onWindowChange = { [weak coordinator] field in
      coordinator?.viewDidMoveToWindow(field)
    }
    return view
  }

  func updateNSView(_ view: Field, context: Context) {
    context.coordinator.text = $text
    context.coordinator.onSubmit = onSubmit
    if view.stringValue != text { view.stringValue = text }
    if view.contentType != contentType { view.contentType = contentType }
    if view.accessibilityLabel() != accessibilityLabel {
      view.setAccessibilityLabel(accessibilityLabel)
    }
    let enabled = context.environment.isEnabled
    if view.isEnabled != enabled { view.isEnabled = enabled }
    context.coordinator.applyFocusIfNeeded(focusRequest, to: view)
  }

  static func dismantleNSView(_ nsView: Field, coordinator: Coordinator) {
    nsView.onWindowChange = nil
    coordinator.pendingFocusRequest = nil
    coordinator.restoreEditorOptions(on: nsView.currentEditor() as? NSTextView)
    if nsView is NSSecureTextField {
      nsView.stringValue = ""
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: Field, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: view.intrinsicContentSize.height)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    private struct EditorOptions {
      let spelling: Bool
      let replacement: Bool
      let completion: Bool
      let quotes: Bool
      let dashes: Bool
    }

    var text: Binding<String>
    var onSubmit: () -> Void
    private var lastAppliedFocusRequest = 0
    var pendingFocusRequest: Int?
    private var savedEditorOptions: EditorOptions?

    init(text: Binding<String>, onSubmit: @escaping () -> Void) {
      self.text = text
      self.onSubmit = onSubmit
    }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
      if let textView = fieldEditor as? NSTextView {
        if savedEditorOptions == nil {
          savedEditorOptions = EditorOptions(
            spelling: textView.isAutomaticSpellingCorrectionEnabled,
            replacement: textView.isAutomaticTextReplacementEnabled,
            completion: textView.isAutomaticTextCompletionEnabled,
            quotes: textView.isAutomaticQuoteSubstitutionEnabled,
            dashes: textView.isAutomaticDashSubstitutionEnabled
          )
        }
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
      }
      return true
    }

    func controlTextDidEndEditing(_ note: Notification) {
      restoreEditorOptions(on: note.userInfo?["NSFieldEditor"] as? NSTextView)
    }

    func controlTextDidChange(_ note: Notification) {
      guard let field = note.object as? NSTextField else { return }
      sync(field.stringValue)
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
      sync(control.stringValue)
      onSubmit()
      return true
    }

    func applyFocusIfNeeded(_ request: Int, to view: NSTextField) {
      guard request > 0, request != lastAppliedFocusRequest else { return }
      guard let window = view.window else {
        pendingFocusRequest = request
        return
      }
      pendingFocusRequest = nil
      lastAppliedFocusRequest = request
      guard view.isEnabled else { return }
      if let editor = view.currentEditor(), window.firstResponder === editor { return }
      window.makeFirstResponder(view)
    }

    func viewDidMoveToWindow(_ view: NSTextField) {
      guard let pending = pendingFocusRequest, view.window != nil else { return }
      applyFocusIfNeeded(pending, to: view)
    }

    func restoreEditorOptions(on textView: NSTextView?) {
      guard let saved = savedEditorOptions, let textView else { return }
      textView.isAutomaticSpellingCorrectionEnabled = saved.spelling
      textView.isAutomaticTextReplacementEnabled = saved.replacement
      textView.isAutomaticTextCompletionEnabled = saved.completion
      textView.isAutomaticQuoteSubstitutionEnabled = saved.quotes
      textView.isAutomaticDashSubstitutionEnabled = saved.dashes
      savedEditorOptions = nil
    }

    private func sync(_ value: String) {
      if text.wrappedValue != value { text.wrappedValue = value }
    }
  }
}
