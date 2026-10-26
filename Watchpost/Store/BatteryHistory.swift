import Foundation
import Observation

/// Battery readings per camera, kept on this device to forecast when each one needs charging.
///
/// Readings only arrive while Ralo is open, so they're sparse; the forecast fits a line through
/// those since the last charge. The file is encrypted while the device is locked, kept for 60
/// days, and deleted on sign-out.
@MainActor
@Observable
final class BatteryHistory {
    struct Reading: Codable, Equatable {
        let date: Date
        let level: Int
        let isCharging: Bool
    }

    /// The level at which a camera counts as needing a charge.
    nonisolated static let rechargeLevel = 15
    private static let retention: TimeInterval = 60 * 86_400

    private(set) var readings: [String: [Reading]] = [:]

    init() {
        readings = Self.load()
    }

    func record(cameraId: String, level: Int, isCharging: Bool, at date: Date = Date()) {
        var list = readings[cameraId] ?? []
        if let last = list.last, last.level == level, last.isCharging == isCharging,
           date.timeIntervalSince(last.date) < 6 * 3600 {
            return // Same as a recent reading: adds nothing to the fit.
        }
        list.append(Reading(date: date, level: level, isCharging: isCharging))
        list.removeAll { date.timeIntervalSince($0.date) > Self.retention }
        readings[cameraId] = list
        save()
    }

    func forecast(cameraId: String) -> BatteryForecast? {
        BatteryForecast(readings: readings[cameraId] ?? [])
    }

    /// Forgets every reading, on sign-out.
    static func erase() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Storage

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "battery-history.json")
    }

    private static func load() -> [String: [Reading]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [Reading]].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(readings) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// When a camera will reach `BatteryHistory.rechargeLevel`, from its readings since the last charge.
struct BatteryForecast: Equatable {
    enum State: Equatable {
        /// Plugged in.
        case charging
        /// At or below the recharge level already.
        case rechargeNow
        /// Not enough readings since the last charge to fit a rate yet.
        case learning
        /// Draining at `percentPerDay`; reaches the recharge level at `date`.
        case predicted(date: Date, percentPerDay: Double)
        /// Readings show no measurable drain.
        case steady
    }

    let level: Int
    let state: State
    /// Readings the forecast is based on, and how many days they cover.
    let readingCount: Int
    let span: TimeInterval

    /// Under three days of readings: the rate can still move a lot.
    var isEarly: Bool { span < 3 * 86_400 }

    init?(readings: [BatteryHistory.Reading]) {
        guard let latest = readings.last else { return nil }
        level = latest.level

        // Walk back to the last charge: a charging reading, or the level having jumped up
        // by a few points since the reading before it.
        var segment: [BatteryHistory.Reading] = [latest]
        for reading in readings.dropLast().reversed() {
            guard !reading.isCharging, reading.level > segment[0].level - 3 else { break }
            segment.insert(reading, at: 0)
        }
        readingCount = segment.count
        span = latest.date.timeIntervalSince(segment[0].date)

        if latest.isCharging {
            state = .charging
            return
        }
        if latest.level <= BatteryHistory.rechargeLevel {
            state = .rechargeNow
            return
        }
        let drop = segment[0].level - latest.level
        guard segment.count >= 3, span >= 12 * 3600, drop >= 2 else {
            state = span >= 7 * 86_400 && drop <= 0 ? .steady : .learning
            return
        }

        // Least-squares slope of level against time, in points per day.
        let origin = segment[0].date
        let xs = segment.map { $0.date.timeIntervalSince(origin) / 86_400 }
        let ys = segment.map { Double($0.level) }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        let slope = variance > 0 ? covariance / variance : 0

        guard slope < -0.05 else {
            state = .steady
            return
        }
        let percentPerDay = -slope
        // Count from the latest reading, not the fitted line, so the forecast follows what
        // the camera says now.
        let days = Double(latest.level - BatteryHistory.rechargeLevel) / percentPerDay
        state = .predicted(date: latest.date.addingTimeInterval(days * 86_400), percentPerDay: percentPerDay)
    }
}
