import Foundation
import LocalAuthentication

/// Where the Arlo sign-in is kept between launches: a single Keychain item that only opens
/// after Face ID or the device passcode, holding the token and, if the person chose to stay
/// signed in, the password. Nothing about the account is written anywhere else.
struct SessionVault: Sendable {
    private let keychain = Keychain(service: "com.watchpost.vault")
    private let sessionAccount = "arlo.session"
    private let deviceAccount = "arlo.device-id"
    private let trustAccount = "arlo.trust"

    var hasSession: Bool { keychain.exists(account: sessionAccount) }

    /// A random identifier Arlo uses to recognise this install. Not secret, never shared elsewhere.
    var deviceId: String {
        if let data = keychain.readPlain(account: deviceAccount), let id = String(data: data, encoding: .utf8) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        try? keychain.setPlain(Data(id.utf8), account: deviceAccount)
        return id
    }

    /// Arlo's trust in this device. Useless without the password, so it opens without Face ID,
    /// which lets a manual sign-in skip the code too. Kept on this device only.
    var trust: BrowserTrust? {
        guard let data = keychain.readPlain(account: trustAccount) else { return nil }
        return try? JSONDecoder().decode(BrowserTrust.self, from: data)
    }

    func saveTrust(_ trust: BrowserTrust) {
        guard !trust.cookies.isEmpty, let data = try? JSONEncoder().encode(trust) else { return }
        try? keychain.setPlain(data, account: trustAccount)
    }

    func save(_ signIn: StoredSignIn) throws {
        guard Self.deviceHasPasscode else { throw ArloError.passcodeRequired }
        let data = try JSONEncoder().encode(signIn)
        try keychain.setProtected(data, account: sessionAccount)
    }

    func load(using context: LAContext) async throws -> StoredSignIn {
        let keychain = self.keychain
        let account = sessionAccount
        let data = try await Task.detached(priority: .userInitiated) {
            try keychain.readProtected(account: account, context: context)
        }.value
        if let signIn = try? JSONDecoder().decode(StoredSignIn.self, from: data) {
            return signIn
        }
        // Saved by an earlier version, before "Stay signed in".
        return StoredSignIn(session: try JSONDecoder().decode(ArloSession.self, from: data), password: nil)
    }

    /// Ends the sign-in but keeps Arlo's trust in this device.
    func clear() {
        try? keychain.delete(account: sessionAccount)
    }

    /// Ends the sign-in and makes Arlo treat this device as new.
    func forgetDevice() {
        clear()
        try? keychain.delete(account: trustAccount)
    }

    static var deviceHasPasscode: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
