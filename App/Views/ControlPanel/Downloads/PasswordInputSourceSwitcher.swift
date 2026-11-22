import Carbon

struct PasswordInputSource: Equatable {
  let identifier: String
  let isKeyboardLayout: Bool
}

final class PasswordInputSourceSwitcher {
  typealias SourceReader = () -> PasswordInputSource?
  typealias SourceSelector = (String) -> Bool

  private let currentSource: SourceReader
  private let asciiKeyboardLayout: SourceReader
  private let selectSource: SourceSelector
  private var previousSourceIdentifier: String?
  private var selectedSourceIdentifier: String?

  init(
    currentSource: @escaping SourceReader,
    asciiKeyboardLayout: @escaping SourceReader,
    selectSource: @escaping SourceSelector
  ) {
    self.currentSource = currentSource
    self.asciiKeyboardLayout = asciiKeyboardLayout
    self.selectSource = selectSource
  }

  static func system() -> PasswordInputSourceSwitcher {
    PasswordInputSourceSwitcher(
      currentSource: {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
          return nil
        }
        return Self.info(for: source)
      },
      asciiKeyboardLayout: {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        else {
          return nil
        }
        return Self.info(for: source)
      },
      selectSource: { identifier in
        guard let source = Self.inputSources(matching: [kTISPropertyInputSourceID: identifier])
          .first(where: { Self.info(for: $0)?.identifier == identifier })
        else { return false }
        return TISSelectInputSource(source) == noErr
      })
  }

  func focus() {
    guard previousSourceIdentifier == nil,
      let previous = currentSource(), !previous.isKeyboardLayout,
      let selected = asciiKeyboardLayout(), selected.isKeyboardLayout,
      selected.identifier != previous.identifier,
      selectSource(selected.identifier)
    else { return }

    previousSourceIdentifier = previous.identifier
    selectedSourceIdentifier = selected.identifier
  }

  func blur() {
    guard let previous = previousSourceIdentifier else { return }
    let selected = selectedSourceIdentifier
    previousSourceIdentifier = nil
    selectedSourceIdentifier = nil
    guard let selected, currentSource()?.identifier == selected else { return }
    _ = selectSource(previous)
  }

  private static func inputSources(matching filter: [CFString: Any]) -> [TISInputSource] {
    (TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource])
      ?? []
  }

  private static func info(for source: TISInputSource) -> PasswordInputSource? {
    guard let identifier = stringProperty(kTISPropertyInputSourceID, of: source),
      let type = stringProperty(kTISPropertyInputSourceType, of: source)
    else { return nil }
    return PasswordInputSource(
      identifier: identifier, isKeyboardLayout: type == (kTISTypeKeyboardLayout! as String))
  }

  private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
    guard let property = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
  }
}
