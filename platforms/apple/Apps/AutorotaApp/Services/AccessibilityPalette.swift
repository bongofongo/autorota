import AutorotaKit
import SwiftUI

enum ColorBlindnessMode: String, CaseIterable {
    case none
    case deuteranopia
    case protanopia
    case tritanopia
    case achromatopsia

    var label: String {
        switch self {
        case .none: String(localized: "None")
        case .deuteranopia: String(localized: "Deuteranopia (red-green)")
        case .protanopia: String(localized: "Protanopia (red-green)")
        case .tritanopia: String(localized: "Tritanopia (blue-yellow)")
        case .achromatopsia: String(localized: "Achromatopsia (monochrome)")
        }
    }

    var shortLabel: String {
        switch self {
        case .none: String(localized: "None")
        case .deuteranopia: String(localized: "Deuteranopia")
        case .protanopia: String(localized: "Protanopia")
        case .tritanopia: String(localized: "Tritanopia")
        case .achromatopsia: String(localized: "Monochrome")
        }
    }
}

struct AccessibilityPalette {
    let yes: Color
    let maybe: Color
    let no: Color
    let proposed: Color
    let confirmed: Color
    let overridden: Color
    let chartPrimary: Color
    let chartSecondary: Color
    let chartTertiary: Color

    func availabilityColor(forState state: String) -> Color {
        switch state {
        case "Yes": yes
        case "No": no
        default: maybe
        }
    }

    func availabilityColor(forSlots slots: [DayAvailabilitySlot]) -> Color {
        guard !slots.isEmpty else { return .gray }
        let hasNo = slots.contains { $0.state == "No" }
        let hasMaybe = slots.contains { $0.state == "Maybe" }
        let hasYes = slots.contains { $0.state == "Yes" }
        if hasNo && !hasYes && !hasMaybe { return no }
        if hasMaybe || (hasYes && hasNo) { return maybe }
        return yes
    }

    func statusColor(for status: String) -> Color {
        switch status {
        case "Proposed": proposed
        case "Confirmed": confirmed
        case "Overridden": overridden
        default: .gray
        }
    }

    static let standard = AccessibilityPalette(
        yes: .green,
        maybe: .yellow,
        no: .red,
        proposed: .orange,
        confirmed: .green,
        overridden: .blue,
        chartPrimary: .blue,
        chartSecondary: .orange,
        chartTertiary: .green
    )

    // Okabe-Ito palette: distinguishable for deutan/protan vision.
    // Yes=sky blue, Maybe=orange, No=vermillion.
    static let deuteranopia = AccessibilityPalette(
        yes: Color(red: 0.337, green: 0.706, blue: 0.914),    // #56B4E9
        maybe: Color(red: 0.902, green: 0.624, blue: 0.000),  // #E69F00
        no: Color(red: 0.835, green: 0.369, blue: 0.000),     // #D55E00
        proposed: Color(red: 0.902, green: 0.624, blue: 0.000),
        confirmed: Color(red: 0.337, green: 0.706, blue: 0.914),
        overridden: Color(red: 0.800, green: 0.475, blue: 0.655), // #CC79A7
        chartPrimary: Color(red: 0.000, green: 0.447, blue: 0.698),  // #0072B2
        chartSecondary: Color(red: 0.902, green: 0.624, blue: 0.000),
        chartTertiary: Color(red: 0.000, green: 0.620, blue: 0.451)  // #009E73
    )

    static let protanopia = deuteranopia

    // Tritanopia: avoid blue/yellow conflict. Use red/green/magenta.
    static let tritanopia = AccessibilityPalette(
        yes: Color(red: 0.000, green: 0.620, blue: 0.451),    // #009E73 bluish green
        maybe: Color(red: 0.800, green: 0.475, blue: 0.655),  // #CC79A7 pinkish
        no: Color(red: 0.835, green: 0.369, blue: 0.000),     // #D55E00 vermillion
        proposed: Color(red: 0.800, green: 0.475, blue: 0.655),
        confirmed: Color(red: 0.000, green: 0.620, blue: 0.451),
        overridden: Color(red: 0.500, green: 0.200, blue: 0.600), // deep purple
        chartPrimary: Color(red: 0.835, green: 0.369, blue: 0.000),
        chartSecondary: Color(red: 0.000, green: 0.620, blue: 0.451),
        chartTertiary: Color(red: 0.800, green: 0.475, blue: 0.655)
    )

    // Achromatopsia: rely on luminance only.
    static let achromatopsia = AccessibilityPalette(
        yes: Color(white: 0.78),
        maybe: Color(white: 0.55),
        no: Color(white: 0.22),
        proposed: Color(white: 0.55),
        confirmed: Color(white: 0.78),
        overridden: Color(white: 0.35),
        chartPrimary: Color(white: 0.30),
        chartSecondary: Color(white: 0.55),
        chartTertiary: Color(white: 0.78)
    )

    static func palette(for mode: ColorBlindnessMode) -> AccessibilityPalette {
        switch mode {
        case .none: .standard
        case .deuteranopia: .deuteranopia
        case .protanopia: .protanopia
        case .tritanopia: .tritanopia
        case .achromatopsia: .achromatopsia
        }
    }
}

private struct AccessibilityPaletteKey: EnvironmentKey {
    static let defaultValue: AccessibilityPalette = .standard
}

extension EnvironmentValues {
    var accessibilityPalette: AccessibilityPalette {
        get { self[AccessibilityPaletteKey.self] }
        set { self[AccessibilityPaletteKey.self] = newValue }
    }
}
