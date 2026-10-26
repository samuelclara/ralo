import Foundation
import os

/// Refuses every HTTP redirect, so a token in a header or URL never follows one.
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case options = "OPTIONS"
}

/// The single network path to Arlo.
///
/// - Ephemeral session: no disk cache, no persisted cookies, nothing written to disk. The only
///   cookies that outlive it are Arlo's device-trust cookies, which sign-in hands to the Keychain.
/// - System and configuration-profile proxies are ignored, so a proxy can't sit in the middle.
/// - TLS 1.2 or later only (App Transport Security already forbids plain HTTP).
/// - Redirects are never followed, so the token can't be carried to another host.
/// - Requests are refused unless they go to one of Arlo's credential hosts.
final class ArloTransport: @unchecked Sendable {
    let deviceId: String
    let session: URLSession
    private let cookieStorage: HTTPCookieStorage?
    private let invalidated = OSAllocatedUnfairLock(initialState: false)

    init(deviceId: String) {
        self.deviceId = deviceId
        let configuration = ArloTransport.hardenedConfiguration()
        cookieStorage = configuration.httpCookieStorage
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    /// The cookies Arlo has set on this connection. Only Arlo's hosts can be reached, so they're all Arlo's.
    var cookies: [StoredCookie] {
        (cookieStorage?.cookies ?? []).map(StoredCookie.init)
    }

    func restore(_ cookies: [StoredCookie]) {
        for cookie in cookies.compactMap(\.cookie) {
            cookieStorage?.setCookie(cookie)
        }
    }

    /// Cancels anything in flight and frees the session. The transport can't be used afterwards.
    func invalidate() {
        invalidated.withLock { $0 = true }
        session.invalidateAndCancel()
    }

    static func hardenedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        config.httpShouldSetCookies = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return config
    }

    func send(
        _ method: HTTPMethod,
        host: String,
        path: String,
        query: [URLQueryItem] = [],
        body: JSONObject? = nil,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        guard Arlo.credentialHosts.contains(host) else { throw ArloError.untrustedHost }
        // A request made after a lock or sign-out (e.g. stopping a stream as its screen closes)
        // would raise an Objective-C exception on the invalidated session.
        guard !invalidated.withLock({ $0 }) else { throw CancellationError() }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ArloError.decoding }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpShouldHandleCookies = true
        request.mainDocumentURL = url
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ArloError.decoding }
            return (data, http)
        } catch {
            throw ArloError.wrap(error)
        }
    }

    /// Unwraps Arlo's two response envelopes: `{meta: {code}, data}` and `{success, data}`.
    static func unwrap(_ data: Data, status: Int) throws -> Any {
        if status == 401 { throw ArloError.unauthorized }

        let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        guard (200..<300).contains(status) else {
            if parsed == nil, [403, 429, 503].contains(status) {
                // An HTML page instead of JSON: Cloudflare's bot protection.
                throw ArloError.blocked(status: status)
            }
            if let dict = parsed as? JSONObject, let meta = dict.object("meta") {
                if meta.int("code") == 401 { throw ArloError.unauthorized }
                if let message = meta.string("message") { throw ArloError.server(message: message) }
            }
            throw ArloError.http(status: status)
        }

        if let array = parsed as? [Any] { return array }
        guard let dict = parsed as? JSONObject else { throw ArloError.decoding }

        if let meta = dict.object("meta") {
            let code = meta.int("code") ?? 0
            if code == 200 { return dict["data"] ?? JSONObject() }
            if code == 401 || meta.int("error") == 9204 { throw ArloError.unauthorized }
            throw ArloError.server(message: meta.string("message") ?? "Arlo returned error \(code).")
        }

        if let success = dict.bool("success") {
            if success { return dict["data"] ?? JSONObject() }
            let detail = dict.object("data")
            let message = detail?.string("message") ?? dict.string("message") ?? "Arlo refused the request."
            if detail?.string("error") == "2015" || detail?.string("error") == "2016" {
                throw ArloError.unauthorized
            }
            throw ArloError.server(message: message)
        }

        return dict
    }
}
