import Foundation

/// Fixed values for talking to Arlo's cloud.
///
/// Arlo has no public API. These endpoints and headers mirror the ones Arlo's own web app
/// uses, as documented by the open-source pyaarlo and Scrypted Arlo projects.
enum Arlo {
    static let apiHost = "myapi.arlo.com"
    static let authHost = "ocapi-app.arlo.com"
    static let defaultMQTTHost = "mqtt-cluster.arloxcld.com"

    /// The only hosts that ever receive the Arlo token. Media URLs (snapshots, clips,
    /// live video) are pre-signed and fetched without credentials.
    static let credentialHosts: Set<String> = [apiHost, authHost]

    /// MQTT brokers must live under one of these domains before the token is sent to them.
    static let trustedMQTTSuffixes = [".arloxcld.com", ".arlo.com"]

    static let origin = "https://my.arlo.com"
    static let referer = "https://my.arlo.com/"

    /// Safari on iPad, the client Arlo's web API expects.
    static let userAgent =
        "Mozilla/5.0 (iPad; CPU OS 17_7_2 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"

    /// The Arlo iOS app, used only to start a live stream. Arlo then answers with RTSPS
    /// (H.264 and AAC), which Ralo unpacks itself and hands to the system decoders.
    static let streamUserAgent = "(iPhone15,2 18_1_1) iOS Arlo 5.4.3"

    /// Arlo's RTSPS servers are given as bare IP addresses; their certificate is for `*.wowza.arlo.com`.
    static let streamCertificateName = "stream.wowza.arlo.com"

    enum Path {
        static let auth = "/api/auth"
        static let getFactors = "/api/getFactors"
        static let getFactorId = "/api/getFactorId"
        static let startPairing = "/api/startPairingFactor"
        static let startAuth = "/api/startAuth"
        static let finishAuth = "/api/finishAuth"
        static let validateToken = "/api/validateAccessToken"

        static let session = "/hmsweb/users/session/v3"
        static let devices = "/hmsweb/v2/users/devices"
        static let library = "/hmsweb/users/library"
        static let logout = "/hmsweb/logout"
        static let notifyPrefix = "/hmsweb/users/devices/notify/"
        static let startStream = "/hmsweb/users/devices/startStream"
        static let startRecord = "/hmsweb/users/devices/startRecord"
        static let stopRecord = "/hmsweb/users/devices/stopRecord"
        static let automationActive = "/hmsweb/users/devices/automation/active"
        static let activeModeV3 = "/hmsweb/automation/v3/activeMode"
        static let subscribe = "/hmsweb/client/subscribe"

        static func locations(userId: String) -> String {
            "/hmsdevicemanagement/users/\(userId)/locations"
        }

        static func pushToTalk(userId: String, deviceId: String) -> String {
            "/hmsweb/users/devices/\(userId)_\(deviceId)/pushtotalk"
        }

        static func capabilities(model: String, interfaceVersion: String) -> String {
            "/resources/capabilities/\(model)/\(model)_\(interfaceVersion).json"
        }
    }

    /// Model prefixes, lower-cased, from the Scrypted Arlo plugin.
    enum Models {
        static let spotlight = [
            "vmc2030", "vmc2032", "vmc2050", "vmc2052", "vmc3050", "vmc3052",
            "vmc4040p", "vmc4041p", "vmc4050p", "vmc4060p", "vmc5040", "vml2030", "vml4030",
        ]
        static let floodlight = ["fb1001"]
        static let siren = [
            "fb1001", "vmc2020", "vmc2030", "vmc2032", "vmc2050", "vmc2052", "vmc2060",
            "vmc3050", "vmc3052", "vmc3060", "vmc4030", "vmc4030p", "vmc4040p", "vmc4041p",
            "vmc4050p", "vmc4060p", "vmc5040", "vml2030", "vml4030",
        ]
        static let noBattery = ["avd1001", "vmc2040", "vmc2060", "vmc3040", "vmc3040s", "vmc3060"]
        static let batteryDoorbells = ["avd2001", "avd3001", "avd4001"]
    }

    static func newTransactionId(prefix: String = "web") -> String {
        "\(prefix)!\(UUID().uuidString.lowercased())"
    }

    static func nowMillis() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1000))
    }
}
