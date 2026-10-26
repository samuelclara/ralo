import Foundation

/// One or more clips from the same camera close together in time, shown as a single visit
/// so a person walking up the drive isn't five separate entries.
struct Visit: Identifiable, Hashable, Sendable {
    let id: String
    let cameraId: String
    let clips: [ArloClip]

    var start: Date { clips.map(\.createdAt).min() ?? .distantPast }
    var latest: ArloClip { clips.max { $0.createdAt < $1.createdAt } ?? clips[0] }
    var thumbnailURL: URL? { clips.first { $0.category == category }?.thumbnailURL ?? latest.thumbnailURL }

    /// The most telling thing seen during the visit.
    var category: ClipCategory {
        let priority: [ClipCategory] = [.person, .package, .vehicle, .animal, .other]
        return priority.first { wanted in clips.contains { $0.category == wanted } } ?? .other
    }

    var durationSeconds: Int { clips.compactMap(\.durationSeconds).reduce(0, +) }

    var durationLabel: String {
        String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }

    static func group(_ clips: [ArloClip], byVisit: Bool, gap: TimeInterval = 120) -> [Visit] {
        guard byVisit else {
            return clips.map { Visit(id: $0.id, cameraId: $0.deviceId, clips: [$0]) }
        }
        var visits: [Visit] = []
        let byCamera = Dictionary(grouping: clips, by: \.deviceId)
        for (cameraId, cameraClips) in byCamera {
            let sorted = cameraClips.sorted { $0.createdAt < $1.createdAt }
            var current: [ArloClip] = []
            for clip in sorted {
                if let last = current.last {
                    let lastEnd = last.createdAt.addingTimeInterval(TimeInterval(last.durationSeconds ?? 0))
                    if clip.createdAt.timeIntervalSince(lastEnd) > gap {
                        visits.append(Visit(id: current[0].id, cameraId: cameraId, clips: current))
                        current = []
                    }
                }
                current.append(clip)
            }
            if !current.isEmpty {
                visits.append(Visit(id: current[0].id, cameraId: cameraId, clips: current))
            }
        }
        return visits.sorted { $0.start > $1.start }
    }
}

enum DayPart: String, CaseIterable {
    case night = "Night", evening = "Evening", afternoon = "Afternoon", morning = "Morning", earlyHours = "Early hours"

    init(date: Date) {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0..<6: self = .earlyHours
        case 6..<12: self = .morning
        case 12..<18: self = .afternoon
        case 18..<22: self = .evening
        default: self = .night
        }
    }
}
