import SwiftUI

struct InlineTextStyle: Sendable {
    let palette: ThemePalette
    let fontSize: CGFloat
    let fontDesign: Font.Design
    let lineSpacing: CGFloat
    let baseColor: Color
    let weight: Font.Weight
    let searchQuery: String

    init(
        palette: ThemePalette,
        fontSize: CGFloat,
        fontDesign: Font.Design,
        lineSpacing: CGFloat,
        baseColor: Color? = nil,
        weight: Font.Weight = .regular,
        searchQuery: String = ""
    ) {
        self.palette = palette
        self.fontSize = fontSize
        self.fontDesign = fontDesign
        self.lineSpacing = lineSpacing
        self.baseColor = baseColor ?? palette.primaryText
        self.weight = weight
        self.searchQuery = searchQuery
    }
}

enum InlineMarkdownRenderer {
    static func attributedString(
        from inlines: [MarkdownInline],
        style: InlineTextStyle
    ) -> AttributedString {
        var combined = AttributedString()
        append(
            inlines,
            into: &combined,
            style: style,
            isBold: style.weight == .bold || style.weight == .semibold || style.weight == .heavy,
            isItalic: false,
            isStrikethrough: false,
            isHighlighted: false,
            linkURL: nil
        )
        applySearchHighlightIfNeeded(query: style.searchQuery, to: &combined)
        return combined
    }

    private static func append(
        _ inlines: [MarkdownInline],
        into output: inout AttributedString,
        style: InlineTextStyle,
        isBold: Bool,
        isItalic: Bool,
        isStrikethrough: Bool,
        isHighlighted: Bool,
        linkURL: URL?
    ) {
        for inline in inlines {
            switch inline {
            case .text(let string):
                var part = AttributedString(string)
                part.font = resolvedFont(
                    size: style.fontSize,
                    design: style.fontDesign,
                    baseWeight: style.weight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                part.foregroundColor = linkURL != nil ? style.palette.accent : style.baseColor
                if isStrikethrough {
                    part.strikethroughStyle = .single
                }
                if isHighlighted {
                    part.backgroundColor = style.palette.highlightBackground
                }
                if let linkURL {
                    part.link = linkURL
                    part.underlineStyle = .single
                }
                output.append(part)

            case .strong(let children):
                append(
                    children,
                    into: &output,
                    style: style,
                    isBold: true,
                    isItalic: isItalic,
                    isStrikethrough: isStrikethrough,
                    isHighlighted: isHighlighted,
                    linkURL: linkURL
                )

            case .emphasis(let children):
                append(
                    children,
                    into: &output,
                    style: style,
                    isBold: isBold,
                    isItalic: true,
                    isStrikethrough: isStrikethrough,
                    isHighlighted: isHighlighted,
                    linkURL: linkURL
                )

            case .strikethrough(let children):
                append(
                    children,
                    into: &output,
                    style: style,
                    isBold: isBold,
                    isItalic: isItalic,
                    isStrikethrough: true,
                    isHighlighted: isHighlighted,
                    linkURL: linkURL
                )

            case .highlight(let children):
                append(
                    children,
                    into: &output,
                    style: style,
                    isBold: isBold,
                    isItalic: isItalic,
                    isStrikethrough: isStrikethrough,
                    isHighlighted: true,
                    linkURL: linkURL
                )

            case .code(let code):
                var part = AttributedString(" \(code) ")
                part.font = .system(size: style.fontSize * 0.87, weight: .medium, design: .monospaced)
                part.foregroundColor = linkURL != nil ? style.palette.accent : style.palette.primaryText
                part.backgroundColor = style.palette.codeBackground
                if isStrikethrough {
                    part.strikethroughStyle = .single
                }
                if let linkURL {
                    part.link = linkURL
                }
                output.append(part)

            case .link(let label, let destination):
                let url = makeRouterURL(from: destination)
                append(
                    label,
                    into: &output,
                    style: style,
                    isBold: isBold,
                    isItalic: isItalic,
                    isStrikethrough: isStrikethrough,
                    isHighlighted: isHighlighted,
                    linkURL: url
                )

            case .image(let alt, let urlString):
                let display = alt.isEmpty ? "画像" : alt
                var part = AttributedString("[\(display)]")
                part.font = .system(size: style.fontSize * 0.9, weight: .medium, design: style.fontDesign)
                part.foregroundColor = style.palette.accent
                if let url = makeRouterURL(from: urlString) {
                    part.link = url
                }
                output.append(part)

            case .softBreak:
                output.append(AttributedString(" "))

            case .hardBreak:
                output.append(AttributedString("\n"))
            }
        }
    }

    private static func resolvedFont(
        size: CGFloat,
        design: Font.Design,
        baseWeight: Font.Weight,
        isBold: Bool,
        isItalic: Bool
    ) -> Font {
        let weight: Font.Weight = isBold ? .bold : baseWeight
        let base = Font.system(size: size, weight: weight, design: design)
        return isItalic ? base.italic() : base
    }

    static func makeRouterURL(from destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            let anchor = String(trimmed.dropFirst())
            let encoded = anchor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? anchor
            return URL(string: "markpocket-anchor://open/\(encoded)")
        }

        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return URL(string: "markpocket-rel://open?path=\(encoded)")
    }

    private static func applySearchHighlightIfNeeded(query: String, to attributed: inout AttributedString) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let plain = String(attributed.characters)
        var searchStart = plain.startIndex
        while let range = plain.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<plain.endIndex) {
            let startOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let matchLength = plain.distance(from: range.lowerBound, to: range.upperBound)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: matchLength)
            attributed[attrStart..<attrEnd].backgroundColor = Color.yellow.opacity(0.55)
            attributed[attrStart..<attrEnd].foregroundColor = Color.black
            searchStart = range.upperBound
        }
    }
}

struct InlineMarkdownText: View {
    let inlines: [MarkdownInline]
    let style: InlineTextStyle
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(InlineMarkdownRenderer.attributedString(from: inlines, style: style))
            .multilineTextAlignment(alignment)
            .lineSpacing(style.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
