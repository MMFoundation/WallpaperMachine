import Foundation
import Observation

/// The Steam sign-in made with a QR code, and the one Steam connection the downloads that use
/// it share. The refresh token lives in the keychain; no password is involved.
@MainActor
@Observable
final class SteamNativeSession {
    /// A QR sign-in in progress.
    enum QRState: Equatable {
        case idle
        case starting
        /// Show `url` as a QR code; `scanned` once the phone opened it.
        case waiting(url: String, scanned: Bool)
        case failed(String)
    }

    enum Failure: LocalizedError, Equatable {
        case notSignedIn
        case signInExpired

        var errorDescription: String? {
            switch self {
            case .notSignedIn: String(localized: "Sign in to Steam with a QR code first.")
            case .signInExpired: String(localized: "Steam no longer accepts this QR sign-in. Sign in again with a QR code.")
            }
        }
    }

    /// Logon answers that mean the token itself is no longer good: InvalidPassword,
    /// AccessDenied, Expired and Revoked. Anything else (rate limits, Steam being down) keeps it.
    static let rejectedTokenResults: Set<Int32> = [5, 15, 27, 26]

    private(set) var token: SteamRefreshToken?
    private(set) var qr = QRState.idle
    var accountName: String? { token?.accountName }
    var isSignedIn: Bool { token != nil }

    @ObservationIgnored private let store: any SteamClientTokenStoring
    @ObservationIgnored private let signIn: SteamQRSignIn
    @ObservationIgnored private let makeConnection: @MainActor () -> SteamCMConnection
    @ObservationIgnored private let makeClient: @MainActor (SteamCMConnection) -> SteamContentClient
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var connection: SteamCMConnection?
    @ObservationIgnored private var client: SteamContentClient?
    @ObservationIgnored private var connecting: Task<SteamContentClient, any Error>?
    @ObservationIgnored private var qrTask: Task<Void, Never>?
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var idleDisconnect: Task<Void, Never>?
    /// Called on the main actor after a QR sign-in was approved and saved, or after sign-out.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(store: any SteamClientTokenStoring = KeychainSteamClientTokenStore(),
         signIn: SteamQRSignIn = SteamQRSignIn(),
         deviceName: String = "WallpaperMachine on \(Host.current().localizedName ?? "Mac")",
         makeConnection: @escaping @MainActor () -> SteamCMConnection = { SteamCMConnection() },
         makeClient: @escaping @MainActor (SteamCMConnection) -> SteamContentClient = { SteamContentClient(connection: $0) }) {
        self.store = store
        self.signIn = signIn
        self.deviceName = deviceName
        self.makeConnection = makeConnection
        self.makeClient = makeClient
    }

    /// Reads the saved sign-in off the main thread: the keychain may ask first.
    func restore() async {
        let store = store
        let saved = await Task.detached(priority: .utility) { store.load() }.value
        guard token == nil, let saved else { return }
        if saved.isExpired() {
            store.remove()
            return
        }
        token = saved
    }

    // MARK: - QR sign-in

    /// Starts a QR sign-in, replacing one already showing. The code renews itself until it is
    /// approved, it fails, or `cancelQRSignIn()` is called.
    func beginQRSignIn() {
        qrTask?.cancel()
        qr = .starting
        qrTask = Task { [weak self, signIn, deviceName] in
            do {
                var challenge = try await signIn.begin(deviceName: deviceName)
                self?.qr = .waiting(url: challenge.url, scanned: false)
                while !Task.isCancelled {
                    try await Task.sleep(for: challenge.pollInterval)
                    switch try await signIn.poll(challenge) {
                    case .waiting(let scanned):
                        self?.qr = .waiting(url: challenge.url, scanned: scanned)
                    case .renewed(let next):
                        challenge = next
                        self?.qr = .waiting(url: next.url, scanned: false)
                    case .approved(let token):
                        try self?.adopt(token)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.warn("Steam QR sign-in failed (\(error.localizedDescription))")
                self?.qr = .failed(Self.message(for: error))
            }
        }
    }

    func cancelQRSignIn() {
        qrTask?.cancel()
        qrTask = nil
        qr = .idle
    }

    private func adopt(_ newToken: SteamRefreshToken) throws {
        try store.save(newToken)
        disconnect()
        token = newToken
        qr = .idle
        qrTask = nil
        AppLog.info("Signed in to Steam with a QR code as \(newToken.accountName)")
        onChange?()
    }

    /// Forgets the sign-in on this Mac. Steam keeps the device listed under the account's
    /// authorized devices until the person removes it there.
    func signOut() {
        cancelQRSignIn()
        disconnect()
        store.remove()
        token = nil
        onChange?()
    }

    // MARK: - Shared connection

    /// A content client logged on with the saved token, shared by every download that runs.
    /// Pair each call with `release()` once the download is done with it.
    func contentClient() async throws -> SteamContentClient {
        guard let token else { throw Failure.notSignedIn }
        guard !token.isExpired() else {
            forgetRejectedToken()
            throw Failure.signInExpired
        }
        users += 1
        idleDisconnect?.cancel()
        if let client, let connection, await connection.isLoggedOn { return client }
        if let connecting {
            // Joining a logon already under way: its failure reads the same for every job.
            do {
                return try await connecting.value
            } catch {
                users -= 1
                throw Self.mapped(error)
            }
        }
        // A connection that dropped is closed before another one opens.
        if connection != nil { disconnect() }
        let connection = makeConnection()
        let client = makeClient(connection)
        let deviceName = deviceName
        let task = Task { () throws -> SteamContentClient in
            try await connection.logOn(with: token, machineName: deviceName)
            return client
        }
        connecting = task
        defer { connecting = nil }
        do {
            let ready = try await task.value
            self.connection = connection
            self.client = ready
            return ready
        } catch {
            users -= 1
            let failure = Self.mapped(error)
            if failure as? Failure == .signInExpired { forgetRejectedToken() }
            throw failure
        }
    }

    /// A logon refusal that means the token itself is no longer good becomes `signInExpired`.
    private static func mapped(_ error: any Error) -> any Error {
        if case SteamCMConnection.Failure.logOnRefused(let eresult)? = error as? SteamCMConnection.Failure,
           rejectedTokenResults.contains(eresult) {
            return Failure.signInExpired
        }
        return error
    }

    /// A download is done with the connection; it closes a minute after the last one.
    func release() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        idleDisconnect?.cancel()
        idleDisconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.users == 0 else { return }
            self.disconnect()
        }
    }

    private func forgetRejectedToken() {
        AppLog.warn("Steam no longer accepts the saved QR sign-in; it was removed")
        disconnect()
        store.remove()
        token = nil
        onChange?()
    }

    private func disconnect() {
        idleDisconnect?.cancel()
        idleDisconnect = nil
        if let connection { Task { await connection.logOff() } }
        connection = nil
        client = nil
    }

    static func message(for error: any Error) -> String {
        if let failure = error as? Failure { return failure.localizedDescription }
        if let refused = error as? SteamWebAPIError, refused.eresult == 9 || refused.eresult == 27 {
            return String(localized: "The QR code expired. Show a new one and scan it again.")
        }
        if error is URLError {
            return String(localized: "Could not reach Steam. Check your internet connection and try again.")
        }
        return String(localized: "Steam sign-in failed. Try again.")
    }
}
