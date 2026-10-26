import LocalAuthentication
import Observation
import SwiftUI

/// The app's top-level state: signed out, locked, or unlocked with a live connection to Arlo.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case locked
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var store: CameraStore?
    private(set) var isUnlocking = false
    /// When the person locks on purpose, don't immediately ask for Face ID again.
    private(set) var suppressAutoUnlock = false
    /// Whether the password is kept so an expired Arlo sign-in renews itself.
    private(set) var staysSignedIn = false
    /// Fills in the sign-in screen after Arlo ends a session. Memory only.
    private(set) var lastEmail: String?
    var notice: String?

    let vault = SessionVault()

    /// Monotonic, so changing the device clock can't skip the relock.
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// The unlocked sign-in, kept in memory like the token so it can be renewed. Dropped on lock.
    @ObservationIgnored private var signIn: StoredSignIn?
    @ObservationIgnored private var renewal: Task<Void, Never>?
    @ObservationIgnored private var lastRenewal: ContinuousClock.Instant?

    private static let installedKey = "app.installed"

    func launch() {
        guard phase == .launching else { return }
        // Keychain items outlive an uninstall. A fresh install must not inherit an old sign-in.
        if !UserDefaults.standard.bool(forKey: Self.installedKey) {
            vault.forgetDevice()
            UserDefaults.standard.set(true, forKey: Self.installedKey)
        }
        phase = vault.hasSession ? .locked : .signedOut
    }

    // MARK: Unlock and sign-in

    func unlock() async {
        guard phase == .locked, !isUnlocking else { return }
        suppressAutoUnlock = false
        isUnlocking = true
        defer { isUnlocking = false }
        do {
            let context = try await AppLock.authenticate()
            var stored = try await vault.load(using: context)
            context.invalidate()
            guard phase == .locked else { return }
            if stored.session.expiresSoon, stored.password != nil {
                do {
                    guard let fresh = try await renewed(stored) else {
                        endSignIn(email: stored.session.email,
                                  notice: "Arlo wants to verify this device again. Sign in once more.")
                        return
                    }
                    stored = fresh
                } catch ArloError.badCredentials {
                    endSignIn(email: stored.session.email,
                              notice: "Arlo didn't accept your saved password. Sign in again.")
                    return
                } catch {
                    // Offline or turned away: the current token still works for a few minutes.
                    if stored.session.isExpired || error is CancellationError { throw error }
                }
                guard phase == .locked else { return }
            } else if stored.session.isExpired {
                endSignIn(email: stored.session.email, notice: "Your Arlo sign-in expired. Sign in again.")
                return
            }
            notice = nil
            start(stored)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .notInteractive].contains(error.code) {
            // Stay on the lock screen; the person can try again.
        } catch KeychainError.notFound {
            phase = .signedOut
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Couldn't unlock. Try again."
        }
    }

    func completeSignIn(_ signIn: StoredSignIn) {
        do {
            try vault.save(signIn)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Couldn't store your sign-in securely."
            return
        }
        notice = nil
        start(signIn)
    }

    private func start(_ signIn: StoredSignIn) {
        let store = CameraStore(client: ArloClient(session: signIn.session))
        store.onUnauthorized = { [weak self] in self?.sessionEnded() }
        self.store = store
        self.signIn = signIn
        staysSignedIn = signIn.password != nil
        lastEmail = nil
        phase = .ready
        resume(store)
    }

    private func resume(_ store: CameraStore) {
        startTask?.cancel()
        startTask = Task { await store.start() }
    }

    // MARK: Staying signed in

    /// Signs in again with the saved password. Arlo skips the code because it trusts this device.
    /// Returns nil when Arlo asks for a code anyway.
    private func renewed(_ stored: StoredSignIn) async throws -> StoredSignIn? {
        guard let password = stored.password else { return nil }
        let transport = ArloTransport(deviceId: stored.session.deviceId)
        defer { transport.invalidate() }
        let authenticator = ArloAuthenticator(transport: transport, trust: vault.trust)
        let step = try await authenticator.signIn(email: stored.session.email, password: password)
        guard case .signedIn(let session) = step else { return nil }
        vault.saveTrust(authenticator.trust)
        let fresh = StoredSignIn(session: session, password: password)
        try vault.save(fresh)
        lastRenewal = .now
        return fresh
    }

    /// Turning it off forgets the password at once. Turning it on happens at the next sign-in,
    /// since the password isn't known until then.
    func stopStayingSignedIn() {
        guard var signIn, signIn.password != nil else { return }
        signIn.password = nil
        do {
            try vault.save(signIn)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Couldn't update your sign-in."
            return
        }
        self.signIn = signIn
        staysSignedIn = false
    }

    // MARK: Lock and sign-out

    func lock(manual: Bool = false) {
        guard phase == .ready else { return }
        suppressAutoUnlock = manual
        teardown()
        phase = vault.hasSession ? .locked : .signedOut
    }

    func signOut() async {
        if let store { await store.client.logout() }
        teardown()
        vault.forgetDevice()
        BatteryHistory.erase()
        notice = nil
        phase = .signedOut
    }

    /// Arlo rejected the token. Renew it if the password is kept, otherwise sign out.
    private func sessionEnded() {
        guard phase == .ready, renewal == nil, let signIn else { return }
        // A token that fails right after renewing won't be fixed by renewing again.
        let renewedRecently = lastRenewal.map { ContinuousClock.now - $0 < .seconds(60) } ?? false
        guard signIn.password != nil, !renewedRecently else {
            endSignIn(email: signIn.session.email, notice: ArloError.unauthorized.errorDescription)
            return
        }
        store?.stop()
        renewal = Task {
            let fresh: StoredSignIn?
            var message = ArloError.unauthorized.errorDescription
            do {
                fresh = try await renewed(signIn)
                if fresh == nil { message = "Arlo wants to verify this device again. Sign in once more." }
            } catch {
                fresh = nil
                if case ArloError.badCredentials = error {
                    message = "Arlo didn't accept your saved password. Sign in again."
                }
            }
            guard !Task.isCancelled, phase == .ready else { return }
            renewal = nil
            if let fresh {
                teardown()
                start(fresh)
            } else {
                endSignIn(email: signIn.session.email, notice: message)
            }
        }
    }

    /// Back to the sign-in screen with the email filled in. Arlo's trust in this device is kept.
    private func endSignIn(email: String, notice: String?) {
        teardown()
        vault.clear()
        lastEmail = email
        self.notice = notice
        phase = .signedOut
    }

    /// Drops the token, the password, the event connection, the network sessions and every cached image.
    private func teardown() {
        renewal?.cancel()
        renewal = nil
        signIn = nil
        staysSignedIn = false
        startTask?.cancel()
        startTask = nil
        store?.invalidate()
        store = nil
        Task { await SecureImageLoader.shared.purge() }
    }

    // MARK: Scene

    /// Called once for the whole app, so one iPad window going to the background doesn't lock the others.
    func scenePhaseChanged(to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            backgroundedAt = .now
            if Preferences.lockDelay <= 0 {
                lock()
            } else {
                store?.stop()
            }
        case .active:
            guard let since = backgroundedAt else { return }
            backgroundedAt = nil
            let away = ContinuousClock.now - since
            if phase == .ready {
                if away >= .seconds(Preferences.lockDelay) {
                    lock()
                    Task { await unlock() }
                } else if let store {
                    resume(store)
                }
            } else if phase == .locked && !suppressAutoUnlock {
                Task { await unlock() }
            }
        default:
            break
        }
    }
}
