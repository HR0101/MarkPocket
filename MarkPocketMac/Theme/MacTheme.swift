import SwiftUI

struct MacPalette: Sendable {
    let isDark: Bool
    let canvas: Color
    let sidebar: Color
    let card: Color
    let raised: Color
    let primaryText: Color
    let secondaryText: Color
    let mutedText: Color
    let hairline: Color
    let accent: Color
    let accentTextOnFill: Color
    let positive: Color
    let warning: Color
    let negative: Color

    static func resolve(for colorScheme: ColorScheme) -> MacPalette {
        colorScheme == .dark ? .dark : .light
    }

    static let light = MacPalette(
        isDark: false,
        canvas: Color(red: 0.980, green: 0.973, blue: 0.957),
        sidebar: Color(red: 0.953, green: 0.945, blue: 0.925),
        card: .white,
        raised: Color(red: 0.941, green: 0.929, blue: 0.902),
        primaryText: Color(red: 0.110, green: 0.102, blue: 0.090),
        secondaryText: Color(red: 0.361, green: 0.341, blue: 0.310),
        mutedText: Color(red: 0.518, green: 0.494, blue: 0.455),
        hairline: Color(red: 0.110, green: 0.102, blue: 0.090).opacity(0.08),
        accent: Color(red: 0.180, green: 0.353, blue: 0.675),
        accentTextOnFill: .white,
        positive: Color(red: 0.086, green: 0.502, blue: 0.286),
        warning: Color(red: 0.706, green: 0.412, blue: 0.078),
        negative: Color(red: 0.761, green: 0.231, blue: 0.231)
    )

    static let dark = MacPalette(
        isDark: true,
        canvas: Color(red: 0.082, green: 0.082, blue: 0.078),
        sidebar: Color(red: 0.067, green: 0.067, blue: 0.063),
        card: Color(red: 0.110, green: 0.106, blue: 0.098),
        raised: Color(red: 0.149, green: 0.145, blue: 0.133),
        primaryText: Color(red: 0.925, green: 0.918, blue: 0.894),
        secondaryText: Color(red: 0.639, green: 0.620, blue: 0.576),
        mutedText: Color(red: 0.490, green: 0.471, blue: 0.435),
        hairline: Color(red: 0.925, green: 0.918, blue: 0.894).opacity(0.08),
        accent: Color(red: 0.427, green: 0.588, blue: 0.910),
        accentTextOnFill: Color(red: 0.067, green: 0.067, blue: 0.063),
        positive: Color(red: 0.298, green: 0.765, blue: 0.541),
        warning: Color(red: 0.898, green: 0.643, blue: 0.298),
        negative: Color(red: 0.898, green: 0.420, blue: 0.420)
    )
}
