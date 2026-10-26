import CoreText
import SwiftUI
import UIKit

/// Amber Glass tokens, matching the Stash V2 canvas.
enum AG {
    static let ink950 = Color(hex: 0x0E0E0F)
    static let ink800 = Color(hex: 0x1C1C1F)
    static let ink600 = Color(hex: 0x3A3A3F)
    static let stone500 = Color(hex: 0x6B6B70)
    static let stone300 = Color(hex: 0xC9C8C4)
    static let paper = Color(hex: 0xF2F1EE)
    static let hairline = Color(hex: 0xECEAE6)
    static let butter = Color(hex: 0xF5DE79)
    static let amber = Color(hex: 0xF2A93B)
    static let ember = Color(hex: 0xE2701F)
    static let glacier = Color(hex: 0x7FA6BC)
    static let moss = Color(hex: 0xA3B046)
    static let signal = Color(hex: 0xE5482B)
    static let badgeBackground = Color(hex: 0xFCEBCB)
    static let badgeText = Color(hex: 0x7A4A08)

    static let cardRadius: CGFloat = 28
    static let tileRadius: CGFloat = 20

    static func color(for category: ClipCategory) -> Color {
        switch category {
        case .person: return amber
        case .vehicle: return glacier
        case .package: return butter
        case .animal: return moss
        case .other: return stone300
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum Typeface {
    enum Weight: String, CaseIterable {
        case light = "Urbanist-Light"
        case regular = "Urbanist-Regular"
        case medium = "Urbanist-Medium"
        case semibold = "Urbanist-SemiBold"
    }

    /// Fonts are registered at launch rather than through Info.plist.
    static func register() {
        for weight in Weight.allCases {
            guard let url = Bundle.main.url(forResource: weight.rawValue, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func uiFont(_ weight: Weight, size: CGFloat) -> UIFont {
        UIFont(name: weight.rawValue, size: size) ?? .systemFont(ofSize: size)
    }
}

extension Font {
    /// Urbanist at a design size that still scales with Dynamic Type.
    static func ag(_ size: CGFloat, _ weight: Typeface.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: style)
    }
}

enum NavigationAppearance {
    /// Only fonts and colours: the bar itself stays system Liquid Glass.
    @MainActor
    static func apply() {
        let ink = UIColor(AG.ink950)
        UINavigationBar.appearance().titleTextAttributes = [
            .font: Typeface.uiFont(.semibold, size: 17), .foregroundColor: ink,
        ]
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: Typeface.uiFont(.semibold, size: 32), .foregroundColor: ink,
        ]
    }
}
