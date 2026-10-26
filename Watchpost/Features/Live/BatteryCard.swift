import SwiftUI

/// The camera's battery and when it will need charging, under the live view.
struct BatteryCard: View {
    let forecast: BatteryForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Battery")
            Figure(value: "\(forecast.level)", unit: "%", size: 48)
            BatteryGauge(level: forecast.level)
            VStack(alignment: .leading, spacing: 4) {
                Text(forecast.headline)
                    .font(.ag(16, .medium))
                Text(forecast.detail)
                    .font(.ag(13))
                    .foregroundStyle(AG.stone500)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .agCard()
        .accessibilityElement(children: .combine)
    }
}

/// A bar for the level, with a tick where it counts as needing a charge.
private struct BatteryGauge: View {
    let level: Int

    private var color: Color {
        if level <= BatteryHistory.rechargeLevel { return AG.signal }
        if level <= 40 { return AG.amber }
        return AG.moss
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AG.hairline)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 100)) / 100)
                Rectangle()
                    .fill(AG.stone500.opacity(0.5))
                    .frame(width: 1.5)
                    .offset(x: proxy.size.width * CGFloat(BatteryHistory.rechargeLevel) / 100)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

extension BatteryForecast {
    var headline: String {
        switch state {
        case .charging: return "Charging"
        case .rechargeNow: return "Recharge now"
        case .learning: return "Learning how fast it drains"
        case .steady: return "No measurable drain"
        case .predicted(let date, _):
            return "Recharge \(Self.relative(date)) · \(Self.day(date))"
        }
    }

    var detail: String {
        let threshold = BatteryHistory.rechargeLevel
        switch state {
        case .charging:
            return "The forecast starts again once it's unplugged."
        case .rechargeNow:
            return "It's at or below \(threshold)%."
        case .learning:
            return "A forecast appears after about a day of readings. Ralo reads the battery whenever it's open."
        case .steady:
            return "The level hasn't dropped in a week of readings."
        case .predicted(_, let rate):
            let perDay = rate >= 10 ? "\(Int(rate.rounded()))" : rate.formatted(.number.precision(.fractionLength(1)))
            let days = max(1, Int((span / 86_400).rounded()))
            var text = "When it reaches \(threshold)%. Draining about \(perDay)% a day, from \(readingCount) readings over \(days) day\(days == 1 ? "" : "s")."
            if isEarly { text += " Early estimate: it settles as Ralo sees more readings." }
            return text
        }
    }

    /// A few words for a camera tile, or nil when there's nothing to act on yet.
    var shortLabel: String? {
        switch state {
        case .rechargeNow: return "Recharge now"
        case .predicted(let date, _): return "Recharge \(Self.relative(date))"
        default: return nil
        }
    }

    private static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if date <= Date() || calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        if days < 14 { return "in \(days) days" }
        if days < 60 { return "in about \(Int((Double(days) / 7).rounded())) weeks" }
        return "in about \(Int((Double(days) / 30).rounded())) months"
    }

    private static func day(_ date: Date) -> String {
        let days = date.timeIntervalSinceNow / 86_400
        if days < 60 {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}
