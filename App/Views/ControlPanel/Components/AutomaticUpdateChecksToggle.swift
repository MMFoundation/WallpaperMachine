import SwiftUI

struct AutomaticUpdateChecksToggle: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    Toggle("Check for updates automatically", isOn: Binding(
      get: { controller.updater.checksAutomatically },
      set: { enabled in
        controller.launch(PanelActionCoordinator.key("automaticUpdateChecks"), policy: .latestWins) {
          try await controller.setAutomaticUpdateChecks(enabled)
        }
      }
    ))
    .toggleStyle(.switch)
    .labelsHidden()
    .accessibilityIdentifier("automatic-update-checks")
  }
}
