import SwiftUI

/// The paper ground with the soft amber light in the top corner.
struct LightField: View {
    var body: some View {
        // The glow is an overlay so its fixed 540pt frame never widens the
        // layout; in a ZStack it pushed screens wider than the device.
        AG.paper.overlay(alignment: .topTrailing) {
            Ellipse()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: AG.butter, location: 0),
                            .init(color: AG.amber, location: 0.35),
                            .init(color: AG.ember.opacity(0.7), location: 0.58),
                            .init(color: AG.paper.opacity(0), location: 0.92),
                        ]),
                        center: UnitPoint(x: 0.55, y: 0.45),
                        startRadius: 0,
                        endRadius: 270
                    )
                )
                .frame(width: 540, height: 520)
                .blur(radius: 40)
                .offset(x: 170, y: -60)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// White squircle card.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
            .shadow(color: AG.ink950.opacity(0.04), radius: 1, y: 1)
            .shadow(color: AG.ink950.opacity(0.06), radius: 20, y: 12)
    }
}

/// Ink card with a dusk light behind it, for summaries.
struct InkCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background {
                ZStack {
                    AG.ink800
                    Circle()
                        .fill(AG.glacier.opacity(0.55))
                        .frame(width: 220, height: 220)
                        .blur(radius: 50)
                        .offset(x: -120, y: -80)
                    Circle()
                        .fill(AG.ember.opacity(0.6))
                        .frame(width: 260, height: 260)
                        .blur(radius: 60)
                        .offset(x: 140, y: 90)
                }
                .clipShape(RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
            }
    }
}

extension View {
    func agCard(padding: CGFloat = 20) -> some View { modifier(CardModifier(padding: padding)) }
    func agInkCard() -> some View { modifier(InkCardModifier()) }
}

struct SectionHeader: View {
    let title: String
    var detail: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.ag(15, .medium, relativeTo: .headline))
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .font(.ag(14, .semibold))
                    .underline()
                    .foregroundStyle(AG.ink950)
            } else if let detail {
                Text(detail).font(.ag(12)).foregroundStyle(AG.stone500)
            }
        }
    }
}

/// One oversized light-weight number with a muted unit, Amber Glass's signature.
struct Figure: View {
    let value: String
    var unit: String?
    var size: CGFloat = 64
    var unitColor: Color = AG.stone500

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.ag(size, .light, relativeTo: .largeTitle))
                .tracking(-size * 0.04)
                .contentTransition(.numericText())
            if let unit {
                Text(unit).font(.ag(14)).foregroundStyle(unitColor)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Filter or day chip: ink when selected, frosted glass otherwise.
struct Chip: View {
    let title: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let count {
                    Text("\(count)").font(.ag(12, .medium)).opacity(0.75)
                }
            }
            .font(.ag(14, .medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .foregroundStyle(isSelected ? Color.white : AG.ink950)
            .background {
                if isSelected { Capsule().fill(AG.ink950) }
            }
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .identity : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ag(12, .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(AG.badgeText)
            .background(AG.badgeBackground, in: Capsule())
    }
}

/// A camera's battery over its picture: level, a charging bolt, red when low.
struct BatteryBadge: View {
    let level: Int
    let isCharging: Bool

    private var isLow: Bool { level <= 20 && !isCharging }

    private var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isLow ? AG.signal : .white)
            Text("\(level)%")
                .font(.ag(12, .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(level) percent\(isCharging ? ", charging" : "")")
    }
}

/// A short message pinned over content, e.g. "Snapshot saved".
struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ag(14, .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AG.ember)
            Text(message)
                .font(.ag(14))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
                .font(.ag(14, .semibold))
                .buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct AppMark: View {
    var size: CGFloat = 40
    var inverted = false

    var body: some View {
        ZStack {
            Circle().fill(inverted ? Color.white : AG.ink950)
            Circle()
                .stroke(inverted ? AG.ink950 : .white, lineWidth: size * 0.04)
                .frame(width: size * 0.45, height: size * 0.45)
            Circle()
                .stroke(inverted ? AG.ink950 : .white, lineWidth: size * 0.04)
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
