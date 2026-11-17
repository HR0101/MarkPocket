import SwiftUI
import UIKit

// MARK: - Appearance Settings Sheet

struct AppearanceSettingsSheet: View {
    @Bindable var preferences: ReaderPreferences
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("テーマ") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ReaderTheme.allCases) { theme in
                                let pal = theme.palette(for: systemScheme)
                                let isSelected = preferences.theme == theme
                                Button {
                                    preferences.theme = theme
                                } label: {
                                    VStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(pal.swatchPreview)
                                            .frame(width: 62, height: 48)
                                            .overlay {
                                                Text("Aa")
                                                    .font(.system(size: 16, weight: .semibold, design: preferences.fontDesign.swiftUIDesign))
                                                    .foregroundStyle(pal.primaryText)
                                            }
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2.5 : 1)
                                            }

                                        Text(theme.displayName)
                                            .font(.caption2.weight(isSelected ? .bold : .regular))
                                            .foregroundStyle(isSelected ? Color.accentColor : .primary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("タイポグラフィ") {
                    Picker("フォント", selection: $preferences.fontDesign) {
                        ForEach(ReaderFontDesign.allCases) { design in
                            Text(design.label).tag(design)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("文字サイズ")
                            Spacer()
                            Text("\(Int(preferences.fontSize.rounded())) pt")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller")
                                .foregroundStyle(.secondary)
                            Slider(value: $preferences.fontSize, in: 13...24, step: 0.5)
                            Image(systemName: "textformat.size.larger")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("行間", selection: $preferences.lineSpacing) {
                        ForEach(LineSpacingPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("表示オプション") {
                    Toggle("コード行を折り返す", isOn: $preferences.wrapCodeLines)
                    Toggle("コードの行番号を表示", isOn: $preferences.showCodeLineNumbers)
                    Toggle("フロントマター (YAML) を表示", isOn: $preferences.showFrontmatter)
                }

                Section {
                    Button("初期設定に戻す", role: .destructive) {
                        preferences.resetDefaults()
                    }
                }
            }
            .navigationTitle("表示設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Table of Contents Sheet

struct TableOfContentsSheet: View {
    let document: MarkdownDocument
    let documentTitle: String
    let palette: ThemePalette
    let onSelectHeading: (HeadingEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("ドキュメント情報") {
                    HStack(spacing: 16) {
                        StatBadge(title: "読了目安", value: "約 \(document.stats.estimatedReadingMinutes) 分", icon: "clock")
                        StatBadge(title: "文字・語数", value: "\(document.stats.wordCount)", icon: "textformat.abc")
                        StatBadge(title: "行数", value: "\(document.stats.lineCount)", icon: "list.number")
                    }
                    .padding(.vertical, 4)
                }

                Section("目次 (\(document.headings.count))") {
                    if document.headings.isEmpty {
                        ContentUnavailableView(
                            "見出しがありません",
                            systemImage: "list.bullet.indent",
                            description: Text("`# 見出し` があるドキュメントではセクションへ移動できます")
                        )
                    } else {
                        ForEach(document.headings) { entry in
                            Button {
                                onSelectHeading(entry)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Text("H\(entry.level)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))

                                    Text(entry.text)
                                        .font(.system(size: 14, weight: entry.level <= 2 ? .medium : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)

                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.leading, CGFloat(max(0, entry.level - 1)) * 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(documentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct StatBadge: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Image Lightbox Sheet

struct ImagePreviewSheet: View {
    let item: ImagePreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Group {
                    if let localURL = item.localFileURL, let uiImage = UIImage(contentsOfFile: localURL.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                    } else if let url = URL(string: item.urlString) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .scaledToFit()
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                    }
                }
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(value, 1.0), 4.0)
                        }
                        .onEnded { _ in
                            if scale < 1.05 { scale = 1.0 }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        scale = scale > 1.1 ? 1.0 : 2.2
                    }
                }
            }
            .navigationTitle(item.alt.isEmpty ? "画像プレビュー" : item.alt)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Raw Editor / Copy Sheet

struct RawMarkdownEditorSheet: View {
    let title: String
    let isWritable: Bool
    @State private var draftText: String
    let onSave: (String) -> Void
    let onDuplicateEditable: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        initialText: String,
        isWritable: Bool,
        onSave: @escaping (String) -> Void,
        onDuplicateEditable: @escaping (String) -> Void
    ) {
        self.title = title
        self._draftText = State(initialValue: initialText)
        self.isWritable = isWritable
        self.onSave = onSave
        self.onDuplicateEditable = onDuplicateEditable
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isWritable {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.doc")
                            .foregroundStyle(.orange)
                        Text("外部ファイルは読み取り専用です。編集するには「複製して保存」を押してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("複製して保存") {
                            onDuplicateEditable(draftText)
                            dismiss()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))
                }

                TextEditor(text: $draftText)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, 8)
                    .disabled(!isWritable)
            }
            .navigationTitle(isWritable ? "Markdown を編集" : "Markdown 原文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                if isWritable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            onSave(draftText)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }
}

// MARK: - PDF Export

enum MarkdownPDFExporter {
    @MainActor
    static func exportPDF(title: String, document: MarkdownDocument) -> URL? {
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4
        let margin: CGFloat = 46
        let contentWidth = pageRect.width - margin * 2
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let safeName = title.replacingOccurrences(of: "/", with: "-")
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName.isEmpty ? "Document" : safeName).pdf")

        do {
            try renderer.writePDF(to: outURL) { context in
                var currentY: CGFloat = margin
                context.beginPage()

                func ensureSpace(_ height: CGFloat) {
                    if currentY + height > pageRect.height - margin {
                        context.beginPage()
                        currentY = margin
                    }
                }

                func drawAttributed(_ attr: NSAttributedString, spacingAfter: CGFloat = 10, indent: CGFloat = 0) {
                    let available = max(100, contentWidth - indent)
                    let bounding = attr.boundingRect(
                        with: CGSize(width: available, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    )
                    let height = ceil(bounding.height)
                    ensureSpace(min(height, pageRect.height - margin * 2))
                    attr.draw(with: CGRect(x: margin + indent, y: currentY, width: available, height: height + 4),
                              options: [.usesLineFragmentOrigin, .usesFontLeading],
                              context: nil)
                    currentY += height + spacingAfter
                }

                for block in document.blocks {
                    switch block {
                    case .heading(_, let level, _, _, let plain):
                        let size: CGFloat = level == 1 ? 22 : (level == 2 ? 17 : 14)
                        let attr = NSAttributedString(
                            string: plain,
                            attributes: [
                                .font: UIFont.systemFont(ofSize: size, weight: .bold),
                                .foregroundColor: UIColor.label
                            ]
                        )
                        drawAttributed(attr, spacingAfter: 10)

                    case .paragraph(_, let inlines):
                        let attr = NSAttributedString(
                            string: inlines.plainText,
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 11.5),
                                .foregroundColor: UIColor.label
                            ]
                        )
                        drawAttributed(attr, spacingAfter: 9)

                    case .codeBlock(_, _, let code):
                        let attr = NSAttributedString(
                            string: code,
                            attributes: [
                                .font: UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                                .foregroundColor: UIColor.darkGray
                            ]
                        )
                        drawAttributed(attr, spacingAfter: 10, indent: 10)

                    case .blockquote(_, let alert, _, let inner):
                        let prefix = alert != nil ? "[\(alert!.displayTitle)] " : "│ "
                        let text = prefix + inner.map(\.plainText).joined(separator: "\n")
                        let attr = NSAttributedString(
                            string: text,
                            attributes: [
                                .font: UIFont.italicSystemFont(ofSize: 11),
                                .foregroundColor: UIColor.secondaryLabel
                            ]
                        )
                        drawAttributed(attr, spacingAfter: 10, indent: 14)

                    case .list(_, let ordered, let startIndex, let items):
                        for (idx, item) in items.enumerated() {
                            let marker = item.checked != nil ? (item.checked! ? "☑ " : "☐ ") : (ordered ? "\(startIndex + idx). " : "• ")
                            let attr = NSAttributedString(
                                string: marker + item.plainText,
                                attributes: [
                                    .font: UIFont.systemFont(ofSize: 11.5),
                                    .foregroundColor: UIColor.label
                                ]
                            )
                            drawAttributed(attr, spacingAfter: 5, indent: 12)
                        }
                        currentY += 5

                    case .table(_, let headers, _, let rows):
                        let headerLine = headers.map(\.plainText).joined(separator: "  |  ")
                        let bodyLines = rows.map { $0.map(\.plainText).joined(separator: "  |  ") }.joined(separator: "\n")
                        let full = bodyLines.isEmpty ? headerLine : "\(headerLine)\n\(bodyLines)"
                        let attr = NSAttributedString(
                            string: full,
                            attributes: [
                                .font: UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                                .foregroundColor: UIColor.label
                            ]
                        )
                        drawAttributed(attr, spacingAfter: 12)

                    case .mathBlock(_, let expr):
                        let attr = NSAttributedString(
                            string: expr,
                            attributes: [
                                .font: UIFont.italicSystemFont(ofSize: 11.5),
                                .foregroundColor: UIColor.label
                            ]
                        )
                        drawAttributed(attr, spacingAfter: 10, indent: 16)

                    case .imageBlock(_, let alt, let url):
                        let attr = NSAttributedString(
                            string: "[画像: \(alt.isEmpty ? url : alt)]",
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 10.5),
                                .foregroundColor: UIColor.secondaryLabel
                            ]
                        )
                        drawAttributed(attr, spacingAfter: 10)

                    case .thematicBreak:
                        ensureSpace(16)
                        let ctx = context.cgContext
                        ctx.setStrokeColor(UIColor.separator.cgColor)
                        ctx.setLineWidth(0.75)
                        ctx.move(to: CGPoint(x: margin, y: currentY + 6))
                        ctx.addLine(to: CGPoint(x: pageRect.width - margin, y: currentY + 6))
                        ctx.strokePath()
                        currentY += 16
                    }
                }
            }
            return outURL
        } catch {
            return nil
        }
    }
}
