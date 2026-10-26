import Foundation

/// Non-sensitive settings. Nothing here identifies the account or a camera.
enum PreferenceKey {
    static let alertPeople = "alerts.person"
    static let alertParcels = "alerts.package"
    static let alertVehicles = "alerts.vehicle"
    static let alertAnimals = "alerts.animal"
    static let groupByVisit = "clips.groupByVisit"
    static let lockDelay = "security.lockDelay"
}

enum Preferences {
    static func register() {
        UserDefaults.standard.register(defaults: [
            PreferenceKey.alertPeople: true,
            PreferenceKey.alertParcels: true,
            PreferenceKey.alertVehicles: false,
            PreferenceKey.alertAnimals: false,
            PreferenceKey.groupByVisit: true,
            PreferenceKey.lockDelay: AppLock.LockDelay.immediately.rawValue,
        ])
    }

    static var groupByVisit: Bool { UserDefaults.standard.bool(forKey: PreferenceKey.groupByVisit) }

    static var lockDelay: TimeInterval {
        TimeInterval(UserDefaults.standard.integer(forKey: PreferenceKey.lockDelay))
    }

    static func highlights(_ category: ClipCategory) -> Bool {
        let defaults = UserDefaults.standard
        switch category {
        case .person: return defaults.bool(forKey: PreferenceKey.alertPeople)
        case .package: return defaults.bool(forKey: PreferenceKey.alertParcels)
        case .vehicle: return defaults.bool(forKey: PreferenceKey.alertVehicles)
        case .animal: return defaults.bool(forKey: PreferenceKey.alertAnimals)
        case .other: return false
        }
    }
}
