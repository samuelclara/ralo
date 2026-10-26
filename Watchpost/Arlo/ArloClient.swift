import Foundation

/// Everything Ralo asks Arlo's cloud to do, once signed in.
///
/// The token lives only in this object's memory while the app is unlocked. Locking the app
/// throws the client away; it is rebuilt from the Keychain after Face ID.
final class ArloClient: @unchecked Sendable {
    let session: ArloSession
    let transport: ArloTransport

    init(session: ArloSession) {
        self.session = session
        transport = ArloTransport(deviceId: session.deviceId)
    }

    var webId: String { "\(session.userId)_web" }

    // MARK: Account

    func sessionInfo() async throws -> SessionInfo {
        let reply = try await api(.get, Arlo.Path.session) as? JSONObject ?? [:]
        var mqttHost: String?
        if let raw = reply.string("mqttUrl"), let host = URLComponents(string: raw)?.host ?? URL(string: "wss://\(raw)")?.host {
            mqttHost = host
        }
        return SessionInfo(supportsMultiLocation: reply.bool("supportsMultiLocation") ?? false, mqttHost: mqttHost)
    }

    func logout() async {
        _ = try? await api(.put, Arlo.Path.logout)
    }

    // MARK: Devices

    func devices() async throws -> [ArloDevice] {
        let reply = try await api(.get, Arlo.Path.devices, query: [URLQueryItem(name: "t", value: Arlo.nowMillis())])
        let list = (reply as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        return list.compactMap(ArloDevice.init(json:)).filter(\.isUsable)
    }

    func capabilities(for camera: ArloDevice) async -> CameraCapabilities {
        guard let interface = camera.interfaceVersion, !camera.model.isEmpty else { return .unknown }
        let path = Arlo.Path.capabilities(model: camera.model, interfaceVersion: interface)
        guard
            let result = try? await transport.send(.get, host: Arlo.apiHost, path: path, headers: apiHeaders()),
            result.1.statusCode == 200,
            let json = (try? JSONSerialization.jsonObject(with: result.0)) as? JSONObject
        else { return .unknown }
        let talk = json.object("Capabilities")?.object("PushToTalk") ?? [:]
        let signals = (talk["signal"] as? [String])?.map { $0.lowercased() } ?? []
        return CameraCapabilities(pushToTalk: !talk.isEmpty, usesSIPTalk: signals.contains("sip"))
    }

    // MARK: Modes

    func locations() async throws -> [ArloLocation] {
        let reply = try await api(.get, Arlo.Path.locations(userId: session.userId)) as? JSONObject ?? [:]
        return (reply.objects("userLocations") + reply.objects("sharedLocations")).compactMap(ArloLocation.init(json:))
    }

    func activeMode(location: ArloLocation) async throws -> (mode: SecurityMode?, revision: Int?) {
        let reply = try await api(
            .get, Arlo.Path.activeModeV3,
            query: [URLQueryItem(name: "locationId", value: location.id)],
            headers: locationHeaders()
        ) as? JSONObject ?? [:]
        let raw = reply.object("properties")?.string("mode") ?? ""
        return (SecurityMode(v3Id: raw), reply.int("revision"))
    }

    func setMode(_ mode: SecurityMode, location: ArloLocation, revision: Int?) async throws -> Int? {
        let reply = try await api(
            .put, Arlo.Path.activeModeV3,
            query: [
                URLQueryItem(name: "locationId", value: location.id),
                URLQueryItem(name: "revision", value: String(revision ?? 1)),
            ],
            body: ["mode": mode.v3Id],
            headers: locationHeaders()
        ) as? JSONObject ?? [:]
        return reply.int("revision")
    }

    /// Older accounts: one armed/disarmed state per base station.
    func baseStationModes() async throws -> [String: SecurityMode] {
        let reply = try await api(.get, Arlo.Path.automationActive)
        var result: [String: SecurityMode] = [:]
        for entry in (reply as? [Any])?.compactMap({ $0 as? JSONObject }) ?? [] {
            guard let uniqueId = entry.string("uniqueId") else { continue }
            if let first = (entry["activeModes"] as? [String])?.first, let mode = SecurityMode(v2Id: first) {
                result[uniqueId] = mode
            }
        }
        return result
    }

    func setBaseStationMode(_ mode: SecurityMode, base: ArloDevice) async throws {
        guard let id = mode.v2Id else {
            throw ArloError.unsupported("This Arlo system only has Armed and Disarmed.")
        }
        let body: JSONObject = [
            "activeAutomations": [[
                "deviceId": base.id,
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                "activeModes": [id],
                "activeSchedules": [String](),
            ]],
        ]
        _ = try await api(.post, Arlo.Path.automationActive, body: body)
    }

    // MARK: Library

    func clips(from start: Date, to end: Date) async throws -> [ArloClip] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        let reply = try await api(.post, Arlo.Path.library, body: [
            "dateFrom": formatter.string(from: start),
            "dateTo": formatter.string(from: end),
        ])
        let items = (reply as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        return items.compactMap(ArloClip.init(json:)).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Live view

    func startStream(camera: ArloDevice) async throws -> URL {
        let body: JSONObject = [
            "to": camera.parentId ?? camera.id,
            "from": webId,
            "resource": camera.cameraResource,
            "action": "set",
            "responseUrl": "",
            "publishResponse": true,
            "transId": Arlo.newTransactionId(),
            "properties": ["activityState": "startUserStream", "cameraId": camera.id],
        ]
        // Asked as the Arlo app, Arlo answers with RTSPS. As a browser it offers MPEG-DASH,
        // which its stream servers no longer serve.
        let reply = try await api(.post, Arlo.Path.startStream, body: body, headers: [
            "xcloudId": camera.xCloudId,
            "User-Agent": Arlo.streamUserAgent,
        ])
        guard
            let raw = (reply as? JSONObject)?.string("url"),
            let url = URL(string: raw),
            ["rtsp", "rtsps"].contains(url.scheme?.lowercased()),
            url.host != nil
        else { throw ArloError.unsupported("Arlo offered a stream format Ralo can't play for this camera.") }
        return url
    }

    func stopStream(camera: ArloDevice, base: ArloDevice) async {
        _ = try? await notify(base: base, body: [
            "action": "set",
            "properties": ["activityState": "idle"],
            "publishResponse": true,
            "resource": camera.cameraResource,
        ])
    }

    func startRecording(camera: ArloDevice) async throws {
        _ = try await api(.post, Arlo.Path.startRecord, body: [
            "parentId": camera.parentId ?? camera.id,
            "deviceId": camera.id,
            "olsonTimeZone": TimeZone.current.identifier,
        ], headers: ["xcloudId": camera.xCloudId])
    }

    func stopRecording(camera: ArloDevice) async throws {
        _ = try await api(.post, Arlo.Path.stopRecord, body: [
            "parentId": camera.parentId ?? camera.id,
            "deviceId": camera.id,
        ], headers: ["xcloudId": camera.xCloudId])
    }

    func setSiren(_ on: Bool, camera: ArloDevice, base: ArloDevice) async throws {
        _ = try await notify(base: base, body: [
            "action": "set",
            "resource": "siren/\(camera.id)",
            "publishResponse": true,
            "properties": ["sirenState": on ? "on" : "off", "duration": 300, "volume": 8, "pattern": "alarm"],
        ])
    }

    func setLight(_ on: Bool, camera: ArloDevice, base: ArloDevice) async throws {
        let properties: JSONObject
        if camera.hasFloodlight {
            properties = ["floodlight": ["on": on]]
        } else if camera.hasSpotlight {
            properties = ["spotlight": ["enabled": on]]
        } else {
            throw ArloError.unsupported("This camera has no light.")
        }
        _ = try await notify(base: base, body: [
            "action": "set",
            "resource": camera.cameraResource,
            "publishResponse": true,
            "properties": properties,
        ])
    }

    // MARK: Two-way talk (WebRTC)

    func startPushToTalk(camera: ArloDevice) async throws -> (sessionId: String, iceServers: [IceServer]) {
        let reply = try await api(.get, Arlo.Path.pushToTalk(userId: session.userId, deviceId: camera.id)) as? JSONObject ?? [:]
        guard let sessionId = reply.string("uSessionId") else { throw ArloError.decoding }
        let servers = reply.objects("data").compactMap { entry -> IceServer? in
            guard let url = entry.string("url") ?? entry.string("urls") else { return nil }
            return IceServer(url: url, username: entry.string("username"), credential: entry.string("credential"))
        }
        return (sessionId, servers)
    }

    func sendTalkOffer(_ sdp: String, sessionId: String, camera: ArloDevice, base: ArloDevice) async throws {
        _ = try await notify(base: base, body: [
            "action": "pushToTalk",
            "resource": camera.cameraResource,
            "publishResponse": true,
            "properties": ["data": sdp, "type": "offerSdp", "uSessionId": sessionId],
        ])
    }

    func sendTalkCandidate(_ candidate: String, sessionId: String, camera: ArloDevice, base: ArloDevice) async throws {
        _ = try await notify(base: base, body: [
            "action": "pushToTalk",
            "resource": camera.cameraResource,
            "publishResponse": false,
            "properties": ["data": candidate, "type": "offerCandidate", "uSessionId": sessionId],
        ])
    }

    // MARK: Events

    /// Asks a base station for its cameras' battery, signal and connection. The answer
    /// arrives on the event stream as one `cameras` event listing every camera.
    func requestCameraStates(base: ArloDevice) async {
        _ = try? await notify(base: base, body: [
            "action": "get",
            "resource": "cameras",
            "publishResponse": false,
        ])
    }

    /// Asks a base station to send its events to this session.
    func keepAlive(base: ArloDevice) async {
        _ = try? await notify(base: base, body: [
            "action": "set",
            "resource": "subscriptions/\(webId)",
            "publishResponse": false,
            "properties": ["devices": [base.id]],
        ])
    }

    func eventStreamRequest() throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Arlo.apiHost
        components.path = Arlo.Path.subscribe
        components.queryItems = [URLQueryItem(name: "token", value: session.token)]
        guard let url = components.url else { throw ArloError.decoding }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60 * 60
        for (field, value) in apiHeaders() { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Plumbing

    @discardableResult
    func notify(base: ArloDevice, body: JSONObject) async throws -> Any {
        var body = body
        body["to"] = base.id
        if body["from"] == nil { body["from"] = webId }
        body["transId"] = Arlo.newTransactionId()
        return try await api(.post, Arlo.Path.notifyPrefix + base.id, body: body, headers: ["xcloudId": base.xCloudId])
    }

    func apiHeaders() -> [String: String] {
        [
            "Accept": "application/json",
            "Accept-Language": "en-GB,en;q=0.9,en-US;q=0.8",
            "Auth-Version": "2",
            "Authorization": session.token,
            "Cache-Control": "no-cache",
            "Content-Type": "application/json; charset=utf-8;",
            "Origin": Arlo.origin,
            "Pragma": "no-cache",
            "Referer": Arlo.referer,
            "SchemaVersion": "1",
            "User-Agent": Arlo.userAgent,
        ]
    }

    private func locationHeaders() -> [String: String] {
        ["x-forwarded-user": session.userId, "x-user-device-id": session.userId]
    }

    private func api(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: JSONObject? = nil,
        headers extra: [String: String] = [:]
    ) async throws -> Any {
        let transactionId = "FE!\(UUID().uuidString.lowercased())"
        var headers = apiHeaders()
        headers["x-transaction-id"] = transactionId
        for (field, value) in extra { headers[field] = value }

        var items = query
        items.append(URLQueryItem(name: "eventId", value: transactionId))
        items.append(URLQueryItem(name: "time", value: Arlo.nowMillis()))

        let (data, response) = try await transport.send(
            method, host: Arlo.apiHost, path: path, query: items, body: body, headers: headers
        )
        return try ArloTransport.unwrap(data, status: response.statusCode)
    }
}
