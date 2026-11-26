import Foundation

@MainActor
struct UpdatePresentation {
  let statusText: String
  let actionLabel: String

  init(status: SoftwareUpdateStatus, locale: Locale) {
    if let version = status.waitingVersion {
      statusText = L("Version \(version) is available")
      actionLabel = L("Show Update…")
    } else {
      statusText = status.lastCheckedAt.map { date in
        let time = date.formatted(.relative(presentation: .named).locale(locale))
        return L("Last checked \(time)")
      } ?? L("Updates not yet checked")
      actionLabel = L("Check Now")
    }
  }
}
