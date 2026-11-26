import Foundation

struct AppUpdateNotice: Equatable, Sendable {
    let version: String
    let canCheck: Bool

    @MainActor
    init?(status: SoftwareUpdateStatus) {
        guard status.isAvailable, let version = status.waitingVersion else { return nil }
        self.version = version
        canCheck = status.canCheck
    }
}
