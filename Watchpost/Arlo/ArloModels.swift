import Foundation

/// Arlo's token for this sign-in, as kept in the Keychain.
struct ArloSession: Codable, Equatable, Sendable {
    let token: String
    let userId: String
    let email: String
    let deviceId: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }

    /// Close enough to expiry that it's worth renewing before using it.
    var expiresSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 600
    }
}

/// What gets saved, encrypted and behind Face ID, in the Keychain after sign-in.
/// The password is only kept when the person chose "Stay signed in".
struct StoredSignIn: Codable, Equatable, Sendable {
    var session: ArloSession
    var password: String?
}

/// Proof that Arlo trusts this device, so signing in again skips the verification code.
/// Arlo ties it to the device ID and the cookies it set when the device was paired.
struct BrowserTrust: Codable, Equatable, Sendable {
    var cookies: [StoredCookie]
}

struct StoredCookie: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresAt: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresAt = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
    }

    var cookie: HTTPCookie? {
        if let expiresAt, expiresAt < Date() { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expiresAt { properties[.expires] = expiresAt }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

struct ArloDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let modelId: String
    let parentId: String?
    let xCloudId: String
    let uniqueId: String
    let interfaceVersion: String?
    let state: String
    var lastImageURL: URL?
    var batteryLevel: Int?
    var isCharging = false
    var signalStrength: Int?
    var connectionState: String?
    var allowedMQTTTopics: [String]

    init?(json: JSONObject) {
        guard
            let id = json.string("deviceId"),
            let type = json.string("deviceType")
        else { return nil }
        self.id = id
        self.type = type.lowercased()
        name = json.string("deviceName") ?? "Camera"
        modelId = json.string("modelId") ?? ""
        parentId = json.string("parentId")
        xCloudId = json.string("xCloudId") ?? ""
        uniqueId = json.string("uniqueId") ?? id
        interfaceVersion = json.string("interfaceVersion")
        state = (json.string("state") ?? "unknown").lowercased()
        lastImageURL = json.url("presignedLastImageUrl") ?? json.url("presignedFullFrameSnapshotUrl")
        let properties = json.object("properties") ?? [:]
        batteryLevel = properties.int("batteryLevel")
        isCharging = Self.isCharging(properties) ?? false
        signalStrength = properties.int("signalStrength")
        connectionState = properties.string("connectionState")
        allowedMQTTTopics = (json["allowedMqttTopics"] as? [String]) ?? []
    }

    var model: String { modelId.lowercased() }

    /// `chargingState` is "On"/"Off" on most cameras, "Charging"/"Discharging" on some.
    static func isCharging(_ properties: JSONObject) -> Bool? {
        guard let state = properties.string("chargingState")?.lowercased() else { return nil }
        return state == "on" || state == "charging"
    }
    var isUsable: Bool { state == "provisioned" || state == "synced" }
    var isOwnParent: Bool { parentId == nil || parentId == id }

    var isCamera: Bool {
        if ["camera", "arloq", "arloqs"].contains(type) { return true }
        if type == "doorbell" && model.hasPrefix("avd") { return true }
        return false
    }

    var isBaseStation: Bool {
        ["basestation", "arlobridge", "hub", "arloq", "arloqs"].contains(type) || model == "abc1000"
    }

    var cameraResource: String { "cameras/\(id)" }

    var hasSiren: Bool { Arlo.Models.siren.contains { model.hasPrefix($0) } }
    var hasSpotlight: Bool { Arlo.Models.spotlight.contains { model.hasPrefix($0) } }
    var hasFloodlight: Bool { Arlo.Models.floodlight.contains { model.hasPrefix($0) } }
    var hasLight: Bool { hasSpotlight || hasFloodlight }
    var runsOnBattery: Bool { !Arlo.Models.noBattery.contains { model.hasPrefix($0) } }

    /// A standalone battery camera: pinging it every 30 seconds would drain it.
    var shouldSkipKeepAlive: Bool {
        // Base stations are mains powered, but aren't in the no-battery camera list.
        if isBaseStation { return false }
        if Arlo.Models.batteryDoorbells.contains(where: { model.hasPrefix($0) }) { return true }
        return isOwnParent && runsOnBattery && !["doorbell", "siren", "arloq", "arloqs"].contains(type)
            && !["abc1000", "abc1000a"].contains(model)
    }
}

struct ArloLocation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let gatewayDeviceIds: [String]

    init?(json: JSONObject) {
        guard let id = json.string("locationId") else { return nil }
        self.id = id
        name = json.string("locationName") ?? "Home"
        gatewayDeviceIds = (json["gatewayDeviceIds"] as? [String]) ?? []
    }
}

enum SecurityMode: String, CaseIterable, Identifiable, Sendable {
    case away, home, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .away: return "Away"
        case .home: return "At home"
        case .off: return "Off"
        }
    }

    var caption: String {
        switch self {
        case .away: return "Every camera records and alerts you."
        case .home: return "Arlo's At home rules apply, usually indoor cameras paused."
        case .off: return "Nothing records. Live view still works."
        }
    }

    /// Location-based modes, used by current Arlo accounts.
    var v3Id: String {
        switch self {
        case .away: return "armAway"
        case .home: return "armHome"
        case .off: return "standby"
        }
    }

    init?(v3Id: String) {
        switch v3Id {
        case "armAway": self = .away
        case "armHome": self = .home
        case "standby": self = .off
        default: return nil
        }
    }

    /// Older base-station modes only have armed and disarmed.
    var v2Id: String? {
        switch self {
        case .away: return "mode1"
        case .off: return "mode0"
        case .home: return nil
        }
    }

    init?(v2Id: String) {
        switch v2Id {
        case "mode1": self = .away
        case "mode0": self = .off
        default: return nil
        }
    }
}

enum ClipCategory: String, CaseIterable, Identifiable, Sendable {
    case person, vehicle, package, animal, other

    var id: String { rawValue }

    init(arlo raw: String?) {
        let value = (raw ?? "").lowercased()
        if value.contains("person") || value.contains("people") { self = .person }
        else if value.contains("vehicle") || value.contains("car") { self = .vehicle }
        else if value.contains("package") || value.contains("parcel") { self = .package }
        else if value.contains("animal") || value.contains("pet") { self = .animal }
        else { self = .other }
    }

    var plural: String {
        switch self {
        case .person: return "People"
        case .vehicle: return "Vehicles"
        case .package: return "Parcels"
        case .animal: return "Animals"
        case .other: return "Motion"
        }
    }

    var title: String {
        switch self {
        case .person: return "Person"
        case .vehicle: return "Vehicle"
        case .package: return "Parcel"
        case .animal: return "Animal"
        case .other: return "Motion"
        }
    }
}

struct ArloClip: Identifiable, Hashable, Sendable {
    let id: String
    let deviceId: String
    let createdAt: Date
    let durationSeconds: Int?
    let category: ClipCategory
    let contentURL: URL?
    let thumbnailURL: URL?

    init?(json: JSONObject) {
        guard let deviceId = json.string("deviceId") else { return nil }
        let millis = json.double("utcCreatedDate") ?? json.double("localCreatedDate") ?? 0
        guard millis > 0 else { return nil }
        self.deviceId = deviceId
        createdAt = Date(timeIntervalSince1970: millis / 1000)
        id = "\(deviceId)-\(json.string("name") ?? String(Int64(millis)))"
        durationSeconds = json.int("mediaDurationSecond")
        category = ClipCategory(arlo: json.string("objCategory"))
        contentURL = json.url("presignedContentUrl")
        thumbnailURL = json.url("presignedThumbnailUrl")
    }

    var durationLabel: String {
        guard let durationSeconds else { return "" }
        return String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}

struct CameraCapabilities: Sendable, Equatable {
    var pushToTalk = false
    var usesSIPTalk = false

    static let unknown = CameraCapabilities()
}

struct IceServer: Sendable {
    let url: String
    let username: String?
    let credential: String?

    var javaScriptValue: [String: Any] {
        var value: [String: Any] = ["urls": url]
        if let username { value["username"] = username }
        if let credential { value["credential"] = credential }
        return value
    }
}

struct SessionInfo: Sendable {
    let supportsMultiLocation: Bool
    let mqttHost: String?
}

/// One message from Arlo's event stream.
struct ArloEvent: @unchecked Sendable {
    let raw: JSONObject

    var resource: String { raw.string("resource") ?? "" }
    var action: String { raw.string("action") ?? "" }
    var from: String { raw.string("from") ?? "" }
    var properties: JSONObject { raw.object("properties") ?? [:] }

    /// The device a `cameras/<id>`-style resource refers to.
    var deviceId: String? {
        let parts = resource.split(separator: "/")
        if parts.count == 2 { return String(parts[1]) }
        return nil
    }
}
