import AppKit
import SwiftUI

/// The window an available update opens: the app's icon, what changed in every version since the
/// running one, and **Skip This Version**, **Remind Me Later** or **Install Update**. It follows the
/// store, so a download started here shows its progress in place.
@MainActor
enum UpdateWindow {
  static let defaultContentSize = NSSize(width: 620, height: 540)
  static let minimumContentSize = NSSize(width: 500, height: 420)

  /// What the buttons do; `AppDelegate` owns the update flow and the window.
  struct Actions {
    let skip: () -> Void
    let later: () -> Void
    let install: () -> Void
  }

  /// - Parameter language: The notes translation the window opens with, the app's effective
  ///   language's by default; the title bar's switch changes it for this window only, never the
  ///   app's language.
  static func make(
    store: AppUpdateStore, actions: Actions, language: AppReleaseHistory.Language? = nil
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = String(localized: "Software Update")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    let notesLanguage = UpdateNotesLanguage(
      language ?? AppReleaseHistory.Language(appLanguage: AppLanguageStore.shared.effective))
    let hosting = NSHostingController(
      rootView: UpdateWindowView(store: store, actions: actions, notesLanguage: notesLanguage)
        .panelTheme(theme: AppThemeStore.shared, locale: PanelLocale.shared))
    hosting.sizingOptions = []
    window.contentViewController = hosting
    window.addTitlebarAccessoryViewController(UpdateLanguageAccessory(notesLanguage))
    window.contentMinSize = minimumContentSize
    // Installing a controller can resize the window to its content view's fitting size.
    window.setContentSize(defaultContentSize)
    return window
  }

  /// A note's inline Markdown, links kept and nothing else interpreted: notes come from the
  /// project's own release, but are still read as text, never as a format or a layout.
  static func inlineNotes(_ markdown: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
  }
}

/// The release-notes translation one update window shows.
@MainActor
@Observable
final class UpdateNotesLanguage {
  var selection: AppReleaseHistory.Language

  init(_ selection: AppReleaseHistory.Language) {
    self.selection = selection
  }
}

/// **English / 简体中文 / 한국어** at the right end of the title bar, level with the window
/// buttons. A titlebar accessory, so the title bar's own dragging never swallows its clicks.
@MainActor
final class UpdateLanguageAccessory: NSTitlebarAccessoryViewController {
  private let notesLanguage: UpdateNotesLanguage
  private(set) var control: NSSegmentedControl!

  init(_ notesLanguage: UpdateNotesLanguage) {
    self.notesLanguage = notesLanguage
    super.init(nibName: nil, bundle: nil)
    layoutAttribute = .trailing
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    control = NSSegmentedControl(
      labels: AppReleaseHistory.Language.allCases.map(\.name), trackingMode: .selectOne,
      target: self, action: #selector(changeLanguage))
    control.controlSize = .small
    control.selectedSegment = notesLanguage.selection.rawValue
    control.setAccessibilityLabel(String(localized: "Release notes language"))
    control.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(control)
    NSLayoutConstraint.activate([
      control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
    ])
    container.frame = NSRect(
      x: 0, y: 0, width: control.fittingSize.width + 12, height: 28)
    view = container
  }

  @objc private func changeLanguage() {
    notesLanguage.selection =
      AppReleaseHistory.Language(rawValue: control.selectedSegment) ?? .english
  }
}

struct UpdateWindowView: View {
  let store: AppUpdateStore
  let actions: UpdateWindow.Actions
  let notesLanguage: UpdateNotesLanguage
  @Environment(\.panelTheme) private var theme

  var body: some View {
    @Bindable var store = store
    let state = store.state
    VStack(alignment: .leading, spacing: 16) {
      header(state)
      UpdateNotesBox(releases: store.pendingReleases, language: notesLanguage.selection)
      footer(state, automatic: $store.automaticallyInstallsUpdates)
    }
    .padding(.horizontal, 24)
    // From the window's top edge: just clear of the window buttons and the language switch.
    .padding(.top, 36)
    .padding(.bottom, 20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(theme.surface.background.color)
    .ignoresSafeArea(.container, edges: .top)
    // Release notes link issues and commits on GitHub; nothing else opens from here.
    .environment(\.openURL, OpenURLAction { url in ExternalLink.open(url) ? .handled : .discarded })
  }

  private func header(_ state: AppUpdateState) -> some View {
    HStack(alignment: .top, spacing: 16) {
      Image(nsImage: NSApp.applicationIconImage ?? NSImage())
        .resizable()
        .interpolation(.high)
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Group {
          if case .ready = state {
            Text("A new version of WallpaperMachine is ready to install!")
          } else {
            Text("A new version of WallpaperMachine is available!")
          }
        }
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(theme.surface.text.color)
        .accessibilityAddTraits(.isHeader)
        detail(state)
          .font(.system(size: 13))
          .foregroundStyle(theme.surface.muted.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func detail(_ state: AppUpdateState) -> some View {
    let available = state.availableVersion ?? ""
    let current = state.currentVersion
    switch state {
    case .ready:
      Text("WallpaperMachine \(available) has been downloaded—you have \(current). WallpaperMachine quits and reopens to install it.")
    case .manual:
      Text("WallpaperMachine \(available) is now available—you have \(current). Download it from GitHub Releases.")
    default:
      Text("WallpaperMachine \(available) is now available—you have \(current). Would you like to download it now?")
    }
  }

  private func footer(_ state: AppUpdateState, automatic: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      switch state {
      case .downloading(_, _, let percent, let transferred, let total, _):
        progress(value: min(max(percent / 100, 0), 1)) {
          if total > 0 {
            Text(
              "\(TransferFormat.bytes(Double(transferred), locale: PanelLocale.shared.locale)) of \(TransferFormat.bytes(Double(total), locale: PanelLocale.shared.locale))"
            )
          } else {
            Text("Downloading \(Int(percent))%")
          }
        }
      case .preparing:
        progress(value: nil) { Text("Preparing update…") }
      default:
        Toggle("Automatically download and install updates in the future", isOn: automatic)
          .toggleStyle(.checkbox)
          .font(.system(size: 13))
          .foregroundStyle(theme.surface.text.color)
      }
      HStack(spacing: 10) {
        Button("Skip This Version", action: actions.skip)
          .disabled(state.isBusy)
        Spacer(minLength: 12)
        Button("Remind Me Later", action: actions.later)
          .keyboardShortcut(.cancelAction)
        primary(state)
      }
      .controlSize(.large)
    }
  }

  @ViewBuilder
  private func primary(_ state: AppUpdateState) -> some View {
    Group {
      switch state {
      case .ready: Button("Install and Relaunch", action: actions.install)
      case .manual: Button("Open GitHub Releases", action: actions.install)
      default: Button("Install Update", action: actions.install)
      }
    }
    .buttonStyle(.panelPrimary)
    .keyboardShortcut(.defaultAction)
    .disabled(state.isBusy)
  }

  private func progress(value: Double?, @ViewBuilder label: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let value {
        ProgressView(value: value).progressViewStyle(.linear)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      label()
        .font(.system(size: 11.5))
        .foregroundStyle(theme.surface.muted.color)
    }
  }
}

/// The scrolling box of release notes: each version as a linked badge with its date, then its
/// sections and bullets, issue and commit references linked.
private struct UpdateNotesBox: View {
  let releases: [AppReleaseHistory.Entry]
  let language: AppReleaseHistory.Language
  @Environment(\.panelTheme) private var theme

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 28) {
        ForEach(releases, id: \.version.display) { release in
          block(release)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Another translation starts at the top again.
    .id(language)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.surface.line.color))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Release notes"))
  }

  private func block(_ release: AppReleaseHistory.Entry) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      badge(release)
      ForEach(Array(release.notes(language: language).sections.enumerated()), id: \.offset) { _, section in
        VStack(alignment: .leading, spacing: 6) {
          if !section.title.isEmpty {
            // Known headings (Features, Bug Fixes) are translated; any other reads as given.
            Text(verbatim: PanelLocale.shared.catalogString(section.title))
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(
                section.isHighlights ? theme.accent.accent.color : theme.surface.text.color)
          }
          ForEach(Array(section.markdown.enumerated()), id: \.offset) { _, item in
            if section.isList {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").foregroundStyle(theme.surface.faint.color)
                Text(UpdateWindow.inlineNotes(item))
              }
            } else {
              Text(UpdateWindow.inlineNotes(item))
            }
          }
          .font(.system(size: 13))
          .foregroundStyle(theme.surface.text.color)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func badge(_ release: AppReleaseHistory.Entry) -> some View {
    HStack(spacing: 0) {
      Group {
        if let url = release.url, ExternalLink.isAllowed(url) {
          Link(destination: url) { Text(verbatim: release.version.display) }
        } else {
          Text(verbatim: release.version.display)
        }
      }
      .foregroundStyle(theme.accent.accent.color)
      if let date = release.date {
        Text(verbatim: " (\(date))").foregroundStyle(theme.surface.text.color)
      }
    }
    .font(.system(size: 17, weight: .bold))
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(theme.surface.raised.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(theme.surface.line.color))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}
