import SwiftUI
import UIKit

struct RenderContext {
    let palette: ThemePalette
    let fontSize: CGFloat
    let fontDesign: Font.Design
    let lineSpacing: CGFloat
    let wrapCodeLines: Bool
    let showCodeLineNumbers: Bool
    let isWritable: Bool
    let searchQuery: String
    let activeMatchBlockID: String?
    let baseDirectoryURL: URL?
    let onToggleTask: (Int) -> Void
    let onTapImage: (ImagePreviewItem) -> Void
}

struct ImagePreviewItem: Identifiable, Sendable {
    let id = UUID()
    let alt: String
    let urlString: String
    let localFileURL: URL?
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let context: RenderContext

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                MarkdownSingleBlockView(block: block, context: context)
                    .id(block.id)
            }
        }
    }
}

struct MarkdownSingleBlockView: View {
    let block: MarkdownBlock
    let context: RenderContext

    private var isActiveSearchMatch: Bool {
        context.activeMatchBlockID == block.id
    }

    var body: some View {
        contentView
            .padding(.horizontal, isActiveSearchMatch ? 6 : 0)
            .padding(.vertical, isActiveSearchMatch ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActiveSearchMatch ? context.palette.accent : .clear, lineWidth: 1.5)
            )
    }

    @ViewBuilder
    private var contentView: some View {
        switch block {
        case .heading(_, let level, _, let inlines, _):
            HeadingBlockView(level: level, inlines: inlines, context: context)

        case .paragraph(_, let inlines):
            InlineMarkdownText(
                inlines: inlines,
                style: InlineTextStyle(
                    palette: context.palette,
                    fontSize: context.fontSize,
                    fontDesign: context.fontDesign,
                    lineSpacing: context.lineSpacing,
                    searchQuery: context.searchQuery
                )
            )

        case .codeBlock(_, let language, let code):
            CodeBlockView(language: language, code: code, context: context)

        case .mathBlock(_, let expression):
            MathBlockView(expression: expression, context: context)

        case .blockquote(_, let alert, let titleOverride, let innerBlocks):
            BlockquoteBlockView(
                alert: alert,
                titleOverride: titleOverride,
                blocks: innerBlocks,
                context: context
            )

        case .list(_, let ordered, let startIndex, let items):
            ListBlockView(
                ordered: ordered,
                startIndex: startIndex,
                items: items,
                depth: 0,
                context: context
            )

        case .table(_, let headers, let alignments, let rows):
            TableBlockView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                context: context
            )

        case .imageBlock(_, let alt, let url):
            ImageBlockView(alt: alt, urlString: url, context: context)

        case .thematicBreak:
            Rectangle()
                .fill(context.palette.divider)
                .frame(height: 1)
                .padding(.vertical, 10)
        }
    }
}

// MARK: - Frontmatter Banner

struct FrontmatterBannerView: View {
    let items: [FrontmatterItem]
    let palette: ThemePalette
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.secondaryText)
                    Text("Frontmatter · \(items.count)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.key)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .frame(minWidth: 72, alignment: .leading)
                            Text(item.value)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(palette.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 4)
            } else if let tagsItem = items.first(where: { $0.key.lowercased() == "tags" || $0.key.lowercased() == "tag" }) {
                let tags = tagsItem.value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(palette.secondaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(palette.background, in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(palette.divider, lineWidth: 1)
                                    )
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(palette.secondaryBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(palette.divider, lineWidth: 1)
        )
    }
}

// MARK: - Heading

private struct HeadingBlockView: View {
    let level: Int
    let inlines: [MarkdownInline]
    let context: RenderContext

    private var headingScale: CGFloat {
        switch level {
        case 1: return 1.60
        case 2: return 1.34
        case 3: return 1.18
        case 4: return 1.06
        case 5: return 0.98
        default: return 0.92
        }
    }

    private var topPadding: CGFloat {
        switch level {
        case 1: return 8
        case 2: return 12
        case 3: return 8
        default: return 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineMarkdownText(
                inlines: inlines,
                style: InlineTextStyle(
                    palette: context.palette,
                    fontSize: context.fontSize * headingScale,
                    fontDesign: context.fontDesign,
                    lineSpacing: 2,
                    baseColor: level >= 6 ? context.palette.secondaryText : context.palette.primaryText,
                    weight: level <= 2 ? .semibold : .medium,
                    searchQuery: context.searchQuery
                )
            )

            if level == 1 {
                Rectangle()
                    .fill(context.palette.divider)
                    .frame(height: 1)
            }
        }
        .padding(.top, topPadding)
    }
}

// MARK: - Code Block

private struct CodeBlockView: View {
    let language: String?
    let code: String
    let context: RenderContext

    @State private var didCopy = false
    private let highlighter = SyntaxHighlighter()

    private var codeFontSize: CGFloat {
        max(12, context.fontSize * 0.84)
    }

    private var lines: [String] {
        let split = code.components(separatedBy: "\n")
        return split.isEmpty ? [""] : split
    }

    private var displayLanguage: String {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Code"
        }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(displayLanguage)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(context.palette.secondaryText)

                Text("· \(lines.count)行")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(context.palette.secondaryText.opacity(0.75))

                Spacer()

                Button {
                    UIPasteboard.general.string = code
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.16)) {
                        didCopy = true
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.easeOut(duration: 0.16)) {
                            didCopy = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        Text(didCopy ? "完了" : "コピー")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(didCopy ? context.palette.accent : context.palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(context.palette.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(didCopy ? context.palette.accent.opacity(0.5) : context.palette.divider, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(context.palette.secondaryBackground)

            Rectangle()
                .fill(context.palette.divider)
                .frame(height: 1)

            if context.wrapCodeLines {
                codeContentView
                    .padding(12)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    codeContentView
                        .padding(12)
                }
            }
        }
        .background(context.palette.codeBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(context.palette.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var codeContentView: some View {
        let highlighted = highlighter.highlight(code: code, language: language, isDark: context.palette.isDark)
        HStack(alignment: .top, spacing: 10) {
            if context.showCodeLineNumbers {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, _ in
                        Text("\(idx + 1)")
                            .font(.system(size: codeFontSize, design: .monospaced))
                            .foregroundStyle(context.palette.secondaryText.opacity(0.5))
                            .lineSpacing(3)
                    }
                }
                .accessibilityHidden(true)
            }

            Text(highlighted)
                .font(.system(size: codeFontSize, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: !context.wrapCodeLines, vertical: true)
        }
    }
}

// MARK: - Math Block

private struct MathBlockView: View {
    let expression: String
    let context: RenderContext

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Image(systemName: "function")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(context.palette.accent)
                Text(expression)
                    .font(.system(size: context.fontSize * 0.96, design: .serif).italic())
                    .foregroundStyle(context.palette.primaryText)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(context.palette.secondaryBackground.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(context.palette.divider, lineWidth: 0.6)
        )
    }
}

// MARK: - Blockquote & Callouts

private struct BlockquoteBlockView: View {
    let alert: CalloutKind?
    let titleOverride: String?
    let blocks: [MarkdownBlock]
    let context: RenderContext

    private func calloutColor(_ kind: CalloutKind) -> Color {
        switch kind {
        case .note:
            return context.palette.accent
        case .tip:
            return context.palette.isDark
                ? Color(red: 0.298, green: 0.765, blue: 0.541)
                : Color(red: 0.086, green: 0.502, blue: 0.286)
        case .important:
            return context.palette.isDark
                ? Color(red: 0.541, green: 0.588, blue: 0.875)
                : Color(red: 0.290, green: 0.333, blue: 0.588)
        case .warning:
            return context.palette.isDark
                ? Color(red: 0.898, green: 0.643, blue: 0.298)
                : Color(red: 0.706, green: 0.412, blue: 0.078)
        case .caution:
            return context.palette.isDark
                ? Color(red: 0.898, green: 0.420, blue: 0.420)
                : Color(red: 0.761, green: 0.231, blue: 0.231)
        }
    }

    var body: some View {
        if let alert {
            let tint = calloutColor(alert)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: alert.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint)
                    Text(titleOverride ?? alert.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { inner in
                        MarkdownSingleBlockView(block: inner, context: context)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(context.palette.isDark ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { inner in
                    MarkdownSingleBlockView(block: inner, context: context)
                }
            }
            .foregroundStyle(context.palette.secondaryText)
            .padding(.leading, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(context.palette.blockquoteStripe)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Lists & Task Lists

private struct ListBlockView: View {
    let ordered: Bool
    let startIndex: Int
    let items: [ListItem]
    let depth: Int
    let context: RenderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        listMarkerView(offset: offset, item: item)

                        InlineMarkdownText(
                            inlines: item.inlines,
                            style: InlineTextStyle(
                                palette: context.palette,
                                fontSize: context.fontSize,
                                fontDesign: context.fontDesign,
                                lineSpacing: context.lineSpacing,
                                baseColor: context.palette.primaryText,
                                searchQuery: context.searchQuery
                            )
                        )
                    }

                    if !item.children.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(item.children) { child in
                                if case .list(_, let childOrdered, let childStart, let childItems) = child {
                                    ListBlockView(
                                        ordered: childOrdered,
                                        startIndex: childStart,
                                        items: childItems,
                                        depth: depth + 1,
                                        context: context
                                    )
                                } else {
                                    MarkdownSingleBlockView(block: child, context: context)
                                }
                            }
                        }
                        .padding(.leading, 22)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func listMarkerView(offset: Int, item: ListItem) -> some View {
        if let checked = item.checked {
            Button {
                if let line = item.sourceLine, context.isWritable {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    context.onToggleTask(line)
                }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: context.fontSize * 0.95, weight: .semibold))
                    .foregroundStyle(checked ? context.palette.accent : context.palette.secondaryText)
                    .frame(width: 20, alignment: .center)
            }
            .buttonStyle(.plain)
            .disabled(!context.isWritable || item.sourceLine == nil)
        } else if ordered {
            Text("\(startIndex + offset).")
                .font(.system(size: context.fontSize * 0.92, weight: .semibold, design: context.fontDesign).monospacedDigit())
                .foregroundStyle(context.palette.secondaryText)
                .frame(minWidth: 20, alignment: .trailing)
        } else {
            Text(bulletSymbol(for: depth))
                .font(.system(size: context.fontSize * 0.95, weight: .bold))
                .foregroundStyle(context.palette.accent)
                .frame(width: 16, alignment: .center)
        }
    }

    private func bulletSymbol(for depth: Int) -> String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

// MARK: - GFM Table

private struct TableBlockView: View {
    let headers: [[MarkdownInline]]
    let alignments: [TableAlignment]
    let rows: [[[MarkdownInline]]]
    let context: RenderContext

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { colIndex, cell in
                        let colAlign = colIndex < alignments.count ? alignments[colIndex] : .left
                        InlineMarkdownText(
                            inlines: cell,
                            style: InlineTextStyle(
                                palette: context.palette,
                                fontSize: context.fontSize * 0.90,
                                fontDesign: context.fontDesign,
                                lineSpacing: 2,
                                weight: .bold,
                                searchQuery: context.searchQuery
                            ),
                            alignment: textAlignment(for: colAlign)
                        )
                        .frame(maxWidth: .infinity, alignment: frameAlignment(for: colAlign))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
                .background(context.palette.tableHeaderBackground)

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Rectangle()
                        .fill(context.palette.divider)
                        .frame(height: 0.5)
                        .gridCellUnsizedAxes([.horizontal])

                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            let colAlign = colIndex < alignments.count ? alignments[colIndex] : .left
                            InlineMarkdownText(
                                inlines: cell,
                                style: InlineTextStyle(
                                    palette: context.palette,
                                    fontSize: context.fontSize * 0.89,
                                    fontDesign: context.fontDesign,
                                    lineSpacing: 2,
                                    searchQuery: context.searchQuery
                                ),
                                alignment: textAlignment(for: colAlign)
                            )
                            .frame(maxWidth: .infinity, alignment: frameAlignment(for: colAlign))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                    }
                    .background(rowIndex % 2 == 1 ? context.palette.secondaryBackground.opacity(0.45) : .clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(context.palette.divider, lineWidth: 0.8)
            )
        }
    }

    private func frameAlignment(for align: TableAlignment) -> Alignment {
        switch align {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func textAlignment(for align: TableAlignment) -> TextAlignment {
        switch align {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

// MARK: - Image Block

private struct ImageBlockView: View {
    let alt: String
    let urlString: String
    let context: RenderContext

    private var remoteURL: URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private var localImageURL: URL? {
        guard remoteURL == nil, let base = context.baseDirectoryURL else { return nil }
        let decoded = urlString.removingPercentEncoding ?? urlString
        let candidate = base.appendingPathComponent(decoded).standardizedFileURL
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Group {
                if let remoteURL {
                    AsyncImage(url: remoteURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture {
                                    context.onTapImage(ImagePreviewItem(alt: alt, urlString: urlString, localFileURL: nil))
                                }
                        case .failure:
                            imagePlaceholder(label: alt.isEmpty ? urlString : alt, icon: "photo.badge.exclamationmark")
                        case .empty:
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("画像を読み込み中…")
                                    .font(.caption)
                                    .foregroundStyle(context.palette.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(context.palette.secondaryBackground, in: RoundedRectangle(cornerRadius: 10))
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else if let localURL = localImageURL, let uiImage = UIImage(contentsOfFile: localURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture {
                            context.onTapImage(ImagePreviewItem(alt: alt, urlString: urlString, localFileURL: localURL))
                        }
                } else {
                    imagePlaceholder(label: alt.isEmpty ? urlString : alt, icon: "photo")
                }
            }

            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(context.palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func imagePlaceholder(label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(context.palette.secondaryText)
            Text(label)
                .font(.caption)
                .foregroundStyle(context.palette.secondaryText)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(context.palette.secondaryBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}
