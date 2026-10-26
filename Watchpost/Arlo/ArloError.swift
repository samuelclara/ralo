import Foundation

enum ArloError: LocalizedError, Equatable {
    case badCredentials
    case unauthorized
    case blocked(status: Int)
    case http(status: Int)
    case server(message: String)
    case decoding
    case untrustedHost
    case noTwoFactorOptions
    case twoFactorTimedOut
    case unsupported(String)
    case offline
    case passcodeRequired

    var errorDescription: String? {
        switch self {
        case .badCredentials:
            return "That email or password didn't work with Arlo."
        case .unauthorized:
            return "Your Arlo session has ended. Sign in again."
        case .blocked(let status):
            return "Arlo's servers turned the request away (\(status)). Try again in a minute."
        case .http(let status):
            return "Arlo returned an error (\(status))."
        case .server(let message):
            return message
        case .decoding:
            return "Arlo sent a reply Ralo couldn't read."
        case .untrustedHost:
            return "Blocked a request to an unexpected server."
        case .noTwoFactorOptions:
            return "Your Arlo account has no verification method Ralo can use."
        case .twoFactorTimedOut:
            return "The verification wasn't approved in time."
        case .unsupported(let what):
            return what
        case .offline:
            return "You're offline."
        case .passcodeRequired:
            return "Set a passcode on this device first. Ralo keeps your Arlo sign-in behind it."
        }
    }

    /// Maps transport errors to something a person can act on.
    static func wrap(_ error: Error) -> Error {
        if error is ArloError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return ArloError.offline
            case .cancelled:
                return CancellationError()
            default:
                return error
            }
        }
        return error
    }
}
