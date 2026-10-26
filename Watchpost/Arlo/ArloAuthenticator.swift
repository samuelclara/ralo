import Foundation

struct TwoFactorOption: Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let nickname: String

    var isPush: Bool { type.uppercased() == "PUSH" }

    var label: String {
        switch type.uppercased() {
        case "EMAIL": return "Email \(nickname)"
        case "SMS": return "Text \(nickname)"
        case "PUSH": return "Approve in the Arlo app"
        default: return nickname.isEmpty ? type.capitalized : nickname
        }
    }

    var symbol: String {
        switch type.uppercased() {
        case "EMAIL": return "envelope"
        case "SMS": return "message"
        case "PUSH": return "iphone.badge.checkmark"
        default: return "key"
        }
    }
}

/// A sign-in that passed the password check and is waiting on two-factor verification.
struct PendingSignIn: Sendable {
    fileprivate let token: String
    let userId: String
    let email: String
}

struct TwoFactorChallenge: Sendable {
    fileprivate let factorAuthCode: String
    let option: TwoFactorOption
}

enum SignInStep: Sendable {
    case signedIn(ArloSession)
    case needsTwoFactor(PendingSignIn, [TwoFactorOption])
}

/// Arlo's sign-in flow: password, then a code by email or text, or approval in Arlo's app.
/// Once a code has been accepted, the device is paired as trusted, and later sign-ins skip the code.
///
/// The password is base64-encoded (Arlo's format, not encryption) and sent over TLS to
/// Arlo's auth host. It is never logged.
final class ArloAuthenticator: @unchecked Sendable {
    private let transport: ArloTransport

    /// Pass the trust saved from an earlier sign-in so Arlo recognises this device.
    init(transport: ArloTransport, trust: BrowserTrust? = nil) {
        self.transport = transport
        if let trust { transport.restore(trust.cookies) }
    }

    /// What to save after signing in, so the next sign-in on this device skips the code.
    var trust: BrowserTrust { BrowserTrust(cookies: transport.cookies) }

    func signIn(email: String, password: String) async throws -> SignInStep {
        let passwordB64 = Data(password.utf8).base64EncodedString()
        let body: JSONObject = [
            "email": email,
            "password": passwordB64,
            "language": "en",
            "EnvSource": "prod",
        ]

        let reply: Any
        do {
            await preflight(Arlo.Path.auth)
            reply = try await authRequest(.post, Arlo.Path.auth, body: body, token: nil)
        } catch ArloError.unauthorized {
            throw ArloError.badCredentials
        }

        let parsed = try Self.parseToken(reply)
        if parsed.completed {
            return .signedIn(try await finishSession(token: parsed.token, userId: parsed.userId,
                                                     email: email, expiresAt: parsed.expiresAt))
        }

        let pending = PendingSignIn(token: parsed.token, userId: parsed.userId, email: email)
        if let session = try await trustedSignIn(pending) {
            return .signedIn(session)
        }
        let options = try await factors(for: pending)
        guard !options.isEmpty else { throw ArloError.noTwoFactorOptions }
        return .needsTwoFactor(pending, options)
    }

    func sendCode(_ pending: PendingSignIn, using option: TwoFactorOption) async throws -> TwoFactorChallenge {
        let body: JSONObject = [
            "factorId": option.id,
            "factorType": option.isPush ? "" : "BROWSER",
            "userId": pending.userId,
        ]
        await preflight(Arlo.Path.startAuth, token: pending.token)
        let reply = try await authRequest(.post, Arlo.Path.startAuth, body: body, token: pending.token)
        guard let code = (reply as? JSONObject)?.string("factorAuthCode") else { throw ArloError.decoding }
        return TwoFactorChallenge(factorAuthCode: code, option: option)
    }

    /// For a code factor, pass the code. For push approval, pass nil: this waits up to a minute.
    func finish(_ pending: PendingSignIn, challenge: TwoFactorChallenge, code: String?) async throws -> ArloSession {
        var body: JSONObject = [
            "factorAuthCode": challenge.factorAuthCode,
            "isBrowserTrusted": true,
        ]
        if let code {
            body["otp"] = code.filter(\.isNumber)
        }

        var attempts = 0
        while true {
            do {
                let reply = try await authRequest(.post, Arlo.Path.finishAuth, body: body, token: pending.token)
                let parsed = try Self.parseToken(reply)
                if let browserAuthCode = parsed.browserAuthCode {
                    await pair(browserAuthCode, token: parsed.token)
                }
                return try await finishSession(token: parsed.token, userId: parsed.userId,
                                               email: pending.email, expiresAt: parsed.expiresAt)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if case ArloError.offline = error { throw error }
                attempts += 1
                guard challenge.option.isPush, attempts < 20 else {
                    if challenge.option.isPush { throw ArloError.twoFactorTimedOut }
                    if case ArloError.unauthorized = error {
                        throw ArloError.server(message: "That code didn't work. Check it and try again.")
                    }
                    throw error
                }
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Private

    /// If Arlo already trusts this device, it finishes the sign-in without a code.
    /// Returns nil when it doesn't, and the normal verification follows.
    private func trustedSignIn(_ pending: PendingSignIn) async throws -> ArloSession? {
        do {
            let lookup: JSONObject = ["factorType": "BROWSER", "factorData": "", "userId": pending.userId]
            await preflight(Arlo.Path.getFactorId, token: pending.token)
            let found = try await authRequest(.post, Arlo.Path.getFactorId, body: lookup, token: pending.token)
            guard let factorId = (found as? JSONObject)?.string("factorId") else { return nil }

            let start: JSONObject = ["factorId": factorId, "factorType": "BROWSER", "userId": pending.userId]
            await preflight(Arlo.Path.startAuth, token: pending.token)
            let reply = try await authRequest(.post, Arlo.Path.startAuth, body: start, token: pending.token)
            let parsed = try? Self.parseToken(reply)
            return try await finishSession(token: parsed?.token ?? pending.token, userId: pending.userId,
                                           email: pending.email, expiresAt: parsed?.expiresAt)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    /// Marks this device as trusted. If Arlo refuses, the sign-in still stands; the next one asks for a code.
    private func pair(_ browserAuthCode: String, token: String) async {
        let body: JSONObject = ["factorAuthCode": browserAuthCode, "factorData": "", "factorType": "BROWSER"]
        await preflight(Arlo.Path.startPairing, token: token)
        _ = try? await authRequest(.post, Arlo.Path.startPairing, body: body, token: token)
    }

    private func factors(for pending: PendingSignIn) async throws -> [TwoFactorOption] {
        let reply = try await authRequest(
            .get, Arlo.Path.getFactors,
            query: [URLQueryItem(name: "data", value: String(Int(Date().timeIntervalSince1970)))],
            token: pending.token
        )
        let items = (reply as? JSONObject)?.objects("items") ?? []
        return items.compactMap { item in
            guard let id = item.string("factorId"), let type = item.string("factorType") else { return nil }
            guard ["EMAIL", "SMS", "PUSH"].contains(type.uppercased()) else { return nil }
            let nickname = item.string("displayName") ?? item.string("factorNickname") ?? ""
            return TwoFactorOption(id: id, type: type, nickname: nickname)
        }
    }

    private func finishSession(token: String, userId: String, email: String, expiresAt: Date?) async throws -> ArloSession {
        _ = try await authRequest(
            .get, Arlo.Path.validateToken,
            query: [URLQueryItem(name: "data", value: String(Int(Date().timeIntervalSince1970)))],
            token: token
        )
        return ArloSession(token: token, userId: userId, email: email,
                           deviceId: transport.deviceId, expiresAt: expiresAt)
    }

    private func headers(token: String?) -> [String: String] {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-GB,en;q=0.9,en-US;q=0.8",
            "Cache-Control": "no-cache",
            "Content-Type": "application/json",
            "Origin": Arlo.origin,
            "Pragma": "no-cache",
            "Referer": Arlo.referer,
            "User-Agent": Arlo.userAgent,
            "X-Service-Version": "3",
            "X-User-Device-Automation-Name": "QlJPV1NFUg==",
            "X-User-Device-Id": transport.deviceId,
            "X-User-Device-Type": "BROWSER",
        ]
        if let token {
            headers["Authorization"] = Data(token.utf8).base64EncodedString()
        }
        return headers
    }

    private func authRequest(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: JSONObject? = nil,
        token: String?
    ) async throws -> Any {
        let (data, response) = try await transport.send(
            method, host: Arlo.authHost, path: path, query: query, body: body, headers: headers(token: token)
        )
        return try ArloTransport.unwrap(data, status: response.statusCode)
    }

    /// Browsers send a CORS preflight before each sign-in call; Arlo's edge expects to see it.
    private func preflight(_ path: String, token: String? = nil) async {
        var preflightHeaders = self.headers(token: token)
        preflightHeaders["Access-Control-Request-Method"] = "POST"
        _ = try? await transport.send(.options, host: Arlo.authHost, path: path, headers: preflightHeaders)
    }

    private static func parseToken(_ reply: Any) throws -> (
        token: String, userId: String, completed: Bool, expiresAt: Date?, browserAuthCode: String?
    ) {
        guard let outer = reply as? JSONObject else { throw ArloError.decoding }
        let inner = outer.object("accessToken") ?? outer
        guard let token = inner.string("token") else { throw ArloError.decoding }
        guard let userId = inner.string("userId") ?? outer.string("userId") else { throw ArloError.decoding }

        var completed = inner.bool("authCompleted") ?? outer.bool("authCompleted") ?? false
        let mfaState = (inner.string("MFA_State") ?? outer.string("MFA_State") ?? "").uppercased()
        if mfaState == "DISABLED" || mfaState == "NONE" { completed = true }
        if let mfa = inner.bool("mfa") ?? outer.bool("mfa"), mfa == false { completed = true }

        var expiresAt: Date?
        if let raw = inner.double("expiresIn") ?? outer.double("expiresIn"), raw > 0 {
            if raw > 1_000_000_000_000 {
                expiresAt = Date(timeIntervalSince1970: raw / 1000)
            } else if raw > 1_000_000_000 {
                expiresAt = Date(timeIntervalSince1970: raw)
            } else {
                expiresAt = Date().addingTimeInterval(raw)
            }
        }
        let browserAuthCode = inner.string("browserAuthCode") ?? outer.string("browserAuthCode")
        return (token, userId, completed, expiresAt, browserAuthCode)
    }
}
