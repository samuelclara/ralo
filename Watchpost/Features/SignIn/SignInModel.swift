import Foundation
import Observation

@MainActor
@Observable
final class SignInModel {
    enum Step: Equatable {
        case credentials
        case chooseMethod
        case enterCode
        case waitingForApproval
    }

    var email = ""
    var password = ""
    var code = ""
    var staySignedIn = true
    private(set) var step: Step = .credentials
    private(set) var options: [TwoFactorOption] = []
    private(set) var chosen: TwoFactorOption?
    private(set) var isBusy = false
    var error: String?

    @ObservationIgnored private var transport: ArloTransport?
    @ObservationIgnored private var authenticator: ArloAuthenticator?
    @ObservationIgnored private var pending: PendingSignIn?
    @ObservationIgnored private var challenge: TwoFactorChallenge?
    @ObservationIgnored private var vault: SessionVault?
    /// Held only until sign-in finishes, and only to be saved when staying signed in.
    @ObservationIgnored private var keptPassword: String?
    @ObservationIgnored private var pollTask: Task<ArloSession, Error>?
    /// Bumped by "Start over", so an abandoned attempt can't finish signing in later.
    @ObservationIgnored private var attempt = 0

    var canSubmitCredentials: Bool {
        email.contains("@") && !password.isEmpty && !isBusy
    }

    var canSubmitCode: Bool {
        code.filter(\.isNumber).count >= 4 && !isBusy
    }

    func submitCredentials(vault: SessionVault) async -> StoredSignIn? {
        guard canSubmitCredentials else { return nil }
        guard SessionVault.deviceHasPasscode else {
            error = ArloError.passcodeRequired.errorDescription
            return nil
        }
        startOver()
        let current = attempt
        isBusy = true
        error = nil

        let transport = ArloTransport(deviceId: vault.deviceId)
        let authenticator = ArloAuthenticator(transport: transport, trust: vault.trust)
        self.vault = vault
        self.transport = transport
        self.authenticator = authenticator
        let password = self.password
        self.password = "" // never keep it in the field longer than the request
        keptPassword = staySignedIn ? password : nil

        do {
            let step = try await authenticator.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            guard current == attempt else { return nil }
            switch step {
            case .signedIn(let session):
                return finished(session)
            case .needsTwoFactor(let pending, let options):
                self.pending = pending
                self.options = options
                isBusy = false
                if options.count == 1, let only = options.first {
                    return await choose(only)
                }
                self.step = .chooseMethod
                return nil
            }
        } catch {
            guard current == attempt else { return nil }
            isBusy = false
            self.error = message(for: error)
            return nil
        }
    }

    func choose(_ option: TwoFactorOption) async -> StoredSignIn? {
        guard let authenticator, let pending, !isBusy else { return nil }
        let current = attempt
        isBusy = true
        error = nil
        chosen = option
        do {
            let challenge = try await authenticator.sendCode(pending, using: option)
            guard current == attempt else { return nil }
            self.challenge = challenge
            guard option.isPush else {
                step = .enterCode
                isBusy = false
                return nil
            }
            step = .waitingForApproval
            let poll = Task { try await authenticator.finish(pending, challenge: challenge, code: nil) }
            pollTask = poll
            let session = try await poll.value
            guard current == attempt else { return nil }
            return finished(session)
        } catch {
            guard current == attempt, !(error is CancellationError) else { return nil }
            isBusy = false
            self.error = message(for: error)
            step = options.count > 1 ? .chooseMethod : .credentials
            return nil
        }
    }

    func submitCode() async -> StoredSignIn? {
        guard canSubmitCode, let authenticator, let pending, let challenge else { return nil }
        let current = attempt
        isBusy = true
        error = nil
        do {
            let session = try await authenticator.finish(pending, challenge: challenge, code: code)
            guard current == attempt else { return nil }
            code = ""
            return finished(session)
        } catch {
            guard current == attempt else { return nil }
            isBusy = false
            self.error = message(for: error)
            return nil
        }
    }

    func startOver() {
        attempt += 1
        pollTask?.cancel()
        pollTask = nil
        transport?.invalidate()
        transport = nil
        authenticator = nil
        vault = nil
        keptPassword = nil
        pending = nil
        challenge = nil
        step = .credentials
        options = []
        chosen = nil
        code = ""
        isBusy = false
        error = nil
    }

    /// The app keeps the session, the password if asked to, and Arlo's trust in this device.
    /// The sign-in connection is closed.
    private func finished(_ session: ArloSession) -> StoredSignIn {
        if let authenticator { vault?.saveTrust(authenticator.trust) }
        let signIn = StoredSignIn(session: session, password: keptPassword)
        isBusy = false
        pollTask = nil
        transport?.invalidate()
        transport = nil
        authenticator = nil
        vault = nil
        keptPassword = nil
        pending = nil
        challenge = nil
        return signIn
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Try again."
    }
}
