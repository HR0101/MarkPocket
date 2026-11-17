import Observation
import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case paper
    case sepia
    case midnight
    case oled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "システム"
        case .paper: return "ペーパー"
        case .sepia: return "セピア"
        case .midnight: return "ミッドナイト"
        case .oled: return "OLED"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .paper, .sepia: return .light
        case .midnight, .oled: return .dark
        }
    }

    func palette(for systemScheme: ColorScheme) -> ThemePalette {
        switch self {
        case .system:
            return systemScheme == .dark ? .systemDark : .systemLight
        case .paper:
            return .paper
        case .sepia:
            return .sepia
        case .midnight:
            return .midnight
        case .oled:
            return .oled
        }
    }
}

struct ThemePalette: Sendable {
    let isDark: Bool
    let background: Color
    let secondaryBackground: Color
    let codeBackground: Color
    let tableHeaderBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let divider: Color
    let blockquoteStripe: Color
    let highlightBackground: Color
    let swatchPreview: Color

    static let systemLight = ThemePalette(
        isDark: false,
        background: Color(red: 0.980, green: 0.973, blue: 0.957),
        secondaryBackground: Color(red: 0.949, green: 0.937, blue: 0.914),
        codeBackground: Color(red: 0.953, green: 0.945, blue: 0.925),
        tableHeaderBackground: Color(red: 0.937, green: 0.925, blue: 0.902),
        primaryText: Color(red: 0.110, green: 0.102, blue: 0.090),
        secondaryText: Color(red: 0.361, green: 0.341, blue: 0.310),
        accent: Color(red: 0.180, green: 0.353, blue: 0.675),
        divider: Color(red: 0.110, green: 0.102, blue: 0.090).opacity(0.08),
        blockquoteStripe: Color(red: 0.110, green: 0.102, blue: 0.090).opacity(0.22),
        highlightBackground: Color(red: 0.98, green: 0.91, blue: 0.56),
        swatchPreview: Color(red: 0.980, green: 0.973, blue: 0.957)
    )

    static let systemDark = ThemePalette(
        isDark: true,
        background: Color(red: 0.082, green: 0.082, blue: 0.078),
        secondaryBackground: Color(red: 0.110, green: 0.106, blue: 0.098),
        codeBackground: Color(red: 0.114, green: 0.110, blue: 0.102),
        tableHeaderBackground: Color(red: 0.149, green: 0.145, blue: 0.133),
        primaryText: Color(red: 0.925, green: 0.918, blue: 0.894),
        secondaryText: Color(red: 0.639, green: 0.620, blue: 0.576),
        accent: Color(red: 0.427, green: 0.588, blue: 0.910),
        divider: Color(red: 0.925, green: 0.918, blue: 0.894).opacity(0.08),
        blockquoteStripe: Color(red: 0.925, green: 0.918, blue: 0.894).opacity(0.22),
        highlightBackground: Color(red: 0.46, green: 0.38, blue: 0.10),
        swatchPreview: Color(red: 0.082, green: 0.082, blue: 0.078)
    )

    static let paper = ThemePalette(
        isDark: false,
        background: Color(red: 0.988, green: 0.980, blue: 0.961),
        secondaryBackground: Color(red: 0.955, green: 0.942, blue: 0.915),
        codeBackground: Color(red: 0.945, green: 0.935, blue: 0.910),
        tableHeaderBackground: Color(red: 0.935, green: 0.922, blue: 0.892),
        primaryText: Color(red: 0.14, green: 0.14, blue: 0.13),
        secondaryText: Color(red: 0.43, green: 0.41, blue: 0.38),
        accent: Color(red: 0.20, green: 0.35, blue: 0.82),
        divider: Color(red: 0.87, green: 0.84, blue: 0.80),
        blockquoteStripe: Color(red: 0.72, green: 0.68, blue: 0.62),
        highlightBackground: Color(red: 1.0, green: 0.92, blue: 0.54),
        swatchPreview: Color(red: 0.988, green: 0.980, blue: 0.961)
    )

    static let sepia = ThemePalette(
        isDark: false,
        background: Color(red: 0.957, green: 0.922, blue: 0.847),
        secondaryBackground: Color(red: 0.918, green: 0.875, blue: 0.788),
        codeBackground: Color(red: 0.906, green: 0.863, blue: 0.776),
        tableHeaderBackground: Color(red: 0.894, green: 0.847, blue: 0.753),
        primaryText: Color(red: 0.24, green: 0.18, blue: 0.12),
        secondaryText: Color(red: 0.48, green: 0.39, blue: 0.30),
        accent: Color(red: 0.64, green: 0.29, blue: 0.12),
        divider: Color(red: 0.82, green: 0.76, blue: 0.65),
        blockquoteStripe: Color(red: 0.68, green: 0.56, blue: 0.42),
        highlightBackground: Color(red: 0.98, green: 0.84, blue: 0.45),
        swatchPreview: Color(red: 0.957, green: 0.922, blue: 0.847)
    )

    static let midnight = ThemePalette(
        isDark: true,
        background: Color(red: 0.082, green: 0.106, blue: 0.153),
        secondaryBackground: Color(red: 0.118, green: 0.149, blue: 0.212),
        codeBackground: Color(red: 0.063, green: 0.082, blue: 0.122),
        tableHeaderBackground: Color(red: 0.137, green: 0.173, blue: 0.243),
        primaryText: Color(red: 0.886, green: 0.910, blue: 0.953),
        secondaryText: Color(red: 0.580, green: 0.643, blue: 0.745),
        accent: Color(red: 0.455, green: 0.655, blue: 0.992),
        divider: Color(red: 0.200, green: 0.247, blue: 0.333),
        blockquoteStripe: Color(red: 0.345, green: 0.435, blue: 0.584),
        highlightBackground: Color(red: 0.46, green: 0.37, blue: 0.09),
        swatchPreview: Color(red: 0.082, green: 0.106, blue: 0.153)
    )

    static let oled = ThemePalette(
        isDark: true,
        background: .black,
        secondaryBackground: Color(red: 0.09, green: 0.09, blue: 0.10),
        codeBackground: Color(red: 0.075, green: 0.075, blue: 0.085),
        tableHeaderBackground: Color(red: 0.12, green: 0.12, blue: 0.14),
        primaryText: Color(red: 0.91, green: 0.92, blue: 0.94),
        secondaryText: Color(red: 0.58, green: 0.60, blue: 0.65),
        accent: Color(red: 0.44, green: 0.62, blue: 1.0),
        divider: Color(red: 0.18, green: 0.19, blue: 0.22),
        blockquoteStripe: Color(red: 0.32, green: 0.35, blue: 0.42),
        highlightBackground: Color(red: 0.45, green: 0.36, blue: 0.08),
        swatchPreview: .black
    )
}

enum ReaderFontDesign: String, CaseIterable, Identifiable, Sendable {
    case sans
    case serif
    case mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans: return "ゴシック"
        case .serif: return "明朝"
        case .mono: return "等幅"
        }
    }

    var swiftUIDesign: Font.Design {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

enum LineSpacingPreset: String, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable
    case relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "狭め"
        case .comfortable: return "標準"
        case .relaxed: return "広め"
        }
    }

    var points: CGFloat {
        switch self {
        case .compact: return 3
        case .comfortable: return 6
        case .relaxed: return 10
        }
    }
}

@MainActor
@Observable
final class ReaderPreferences {
    var theme: ReaderTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    var fontDesign: ReaderFontDesign {
        didSet { UserDefaults.standard.set(fontDesign.rawValue, forKey: Keys.fontDesign) }
    }

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    var lineSpacing: LineSpacingPreset {
        didSet { UserDefaults.standard.set(lineSpacing.rawValue, forKey: Keys.lineSpacing) }
    }

    var wrapCodeLines: Bool {
        didSet { UserDefaults.standard.set(wrapCodeLines, forKey: Keys.wrapCodeLines) }
    }

    var showCodeLineNumbers: Bool {
        didSet { UserDefaults.standard.set(showCodeLineNumbers, forKey: Keys.showCodeLineNumbers) }
    }

    var showFrontmatter: Bool {
        didSet { UserDefaults.standard.set(showFrontmatter, forKey: Keys.showFrontmatter) }
    }

    private enum Keys {
        static let theme = "markpocket.reader.theme"
        static let fontDesign = "markpocket.reader.fontDesign"
        static let fontSize = "markpocket.reader.fontSize"
        static let lineSpacing = "markpocket.reader.lineSpacing"
        static let wrapCodeLines = "markpocket.reader.wrapCodeLines"
        static let showCodeLineNumbers = "markpocket.reader.showCodeLineNumbers"
        static let showFrontmatter = "markpocket.reader.showFrontmatter"
    }

    init() {
        let defaults = UserDefaults.standard
        self.theme = ReaderTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        self.fontDesign = ReaderFontDesign(rawValue: defaults.string(forKey: Keys.fontDesign) ?? "") ?? .sans
        let savedSize = defaults.double(forKey: Keys.fontSize)
        self.fontSize = savedSize > 0 ? min(max(savedSize, 13), 24) : 16.5
        self.lineSpacing = LineSpacingPreset(rawValue: defaults.string(forKey: Keys.lineSpacing) ?? "") ?? .comfortable
        self.wrapCodeLines = defaults.object(forKey: Keys.wrapCodeLines) as? Bool ?? false
        self.showCodeLineNumbers = defaults.object(forKey: Keys.showCodeLineNumbers) as? Bool ?? true
        self.showFrontmatter = defaults.object(forKey: Keys.showFrontmatter) as? Bool ?? true
    }

    func resetDefaults() {
        theme = .system
        fontDesign = .sans
        fontSize = 16.5
        lineSpacing = .comfortable
        wrapCodeLines = false
        showCodeLineNumbers = true
        showFrontmatter = true
    }
}
