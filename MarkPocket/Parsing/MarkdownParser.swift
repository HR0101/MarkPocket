import Foundation

/// Pure Swift Markdown parser producing a structured AST (`MarkdownDocument`)
/// suitable for mobile rendering, table-of-contents navigation, and search.
struct MarkdownParser: Sendable {

    nonisolated init() {}

    nonisolated func parse(_ source: String) -> MarkdownDocument {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let allLines = normalized.components(separatedBy: "\n")
        let lineCount = allLines.count

        let (frontmatter, bodyStartIndex) = extractFrontmatter(from: allLines)
        var headingCounts: [String: Int] = [:]
        let rootSlice = allLines[bodyStartIndex...]
        let rootLineNumbers = Array(0..<allLines.count)[bodyStartIndex...]
        let blocks = parseBlocks(
            from: rootSlice,
            lineNumbers: rootLineNumbers[...],
            idPrefix: "b",
            headingCounts: &headingCounts
        )

        var headings: [HeadingEntry] = []
        var codeBlockCount = 0
        collectStatsAndHeadings(from: blocks, headings: &headings, codeBlockCount: &codeBlockCount)

        let stats = computeStats(
            rawSource: normalized,
            lineCount: lineCount,
            headingCount: headings.count,
            codeBlockCount: codeBlockCount
        )

        return MarkdownDocument(
            frontmatter: frontmatter,
            blocks: blocks,
            headings: headings,
            stats: stats
        )
    }

    // MARK: - Frontmatter

    private nonisolated func extractFrontmatter(from lines: [String]) -> ([FrontmatterItem], Int) {
        guard lines.count >= 3,
              lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return ([], 0)
        }

        var closingIndex: Int?
        let maxSearch = min(lines.count, 80)
        for i in 1..<maxSearch {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                closingIndex = i
                break
            }
        }

        guard let endIdx = closingIndex, endIdx > 1 else {
            return ([], 0)
        }

        // Verify at least one YAML-like key:value line exists so a normal HR isn't misclassified.
        let slice = Array(lines[1..<endIdx])
        let items = parseYAMLFrontmatterLines(slice)
        guard !items.isEmpty else {
            return ([], 0)
        }

        return (items, endIdx + 1)
    }

    private nonisolated func parseYAMLFrontmatterLines(_ lines: [String]) -> [FrontmatterItem] {
        var items: [FrontmatterItem] = []
        var currentKey: String?
        var listBuffer: [String] = []

        func flushList() {
            if let key = currentKey, !listBuffer.isEmpty {
                items.append(FrontmatterItem(key: key, value: listBuffer.joined(separator: ", ")))
                listBuffer.removeAll()
                currentKey = nil
            }
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("- "), currentKey != nil {
                let val = stripSurroundingQuotes(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                if !val.isEmpty { listBuffer.append(val) }
                continue
            }

            if let colonIndex = rawLine.firstIndex(of: ":") {
                flushList()
                let key = rawLine[..<colonIndex].trimmingCharacters(in: .whitespaces)
                let afterColon = rawLine[rawLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !key.contains(" ") else { continue }

                if afterColon.isEmpty {
                    currentKey = key
                } else {
                    let cleaned = cleanYAMLInlineValue(afterColon)
                    items.append(FrontmatterItem(key: key, value: cleaned))
                    currentKey = nil
                }
            }
        }
        flushList()
        return items
    }

    private nonisolated func cleanYAMLInlineValue(_ raw: String) -> String {
        var val = raw
        if val.hasPrefix("[") && val.hasSuffix("]") && val.count >= 2 {
            val = String(val.dropFirst().dropLast())
            let parts = val.split(separator: ",").map {
                stripSurroundingQuotes($0.trimmingCharacters(in: .whitespaces))
            }
            return parts.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return stripSurroundingQuotes(val)
    }

    private nonisolated func stripSurroundingQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Block Parsing

    private nonisolated func parseBlocks(
        from slice: ArraySlice<String>,
        lineNumbers: ArraySlice<Int>,
        idPrefix: String,
        headingCounts: inout [String: Int]
    ) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var blockIndex = 0
        var index = slice.startIndex

        func nextID() -> String {
            defer { blockIndex += 1 }
            return "\(idPrefix)-\(blockIndex)"
        }

        while index < slice.endIndex {
            let line = slice[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Multi-line or single-line HTML comment
            if trimmed.hasPrefix("<!--") {
                index = skipHTMLComment(in: slice, from: index)
                continue
            }

            // Fenced code block (``` or ~~~)
            if let fence = parseFenceOpening(line) {
                let (code, nextIdx) = consumeFencedCode(in: slice, from: index + 1, fenceChar: fence.char, fenceLength: fence.length)
                blocks.append(.codeBlock(id: nextID(), language: fence.language, code: code))
                index = nextIdx
                continue
            }

            // Display math block ($$)
            if trimmed == "$$" || (trimmed.hasPrefix("$$") && trimmed.count > 2 && !trimmed.dropFirst(2).contains("$$")) {
                let (expr, nextIdx) = consumeMathBlock(in: slice, from: index)
                blocks.append(.mathBlock(id: nextID(), expression: expr))
                index = nextIdx
                continue
            } else if trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4 {
                let expr = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.mathBlock(id: nextID(), expression: expr))
                index += 1
                continue
            }

            // ATX Heading (# ... ######)
            if let heading = parseATXHeading(line) {
                let inlines = parseInlines(heading.content)
                let plain = inlines.plainText
                let anchor = uniqueAnchor(for: plain, counts: &headingCounts)
                blocks.append(.heading(id: nextID(), level: heading.level, anchor: anchor, inlines: inlines, plainText: plain))
                index += 1
                continue
            }

            // Thematic Break (---, ***, ___)
            if isThematicBreak(line) {
                blocks.append(.thematicBreak(id: nextID()))
                index += 1
                continue
            }

            // Blockquote / Callout (>)
            if isBlockquoteLine(line) {
                let (quoteBlock, nextIdx) = consumeBlockquote(
                    in: slice,
                    lineNumbers: lineNumbers,
                    from: index,
                    blockID: nextID(),
                    headingCounts: &headingCounts
                )
                blocks.append(quoteBlock)
                index = nextIdx
                continue
            }

            // GFM Table
            if let (tableBlock, nextIdx) = tryConsumeTable(in: slice, from: index, blockID: nextID()) {
                blocks.append(tableBlock)
                index = nextIdx
                continue
            }

            // Ordered / Unordered / Task List
            if parseListMarker(line) != nil {
                let (listBlock, nextIdx) = consumeList(
                    in: slice,
                    lineNumbers: lineNumbers,
                    from: index,
                    blockID: nextID(),
                    headingCounts: &headingCounts
                )
                blocks.append(listBlock)
                index = nextIdx
                continue
            }

            // Paragraph (and Setext heading check)
            let (paraBlock, nextIdx) = consumeParagraphOrSetextHeading(
                in: slice,
                from: index,
                blockID: nextID(),
                headingCounts: &headingCounts
            )
            blocks.append(paraBlock)
            index = nextIdx
        }

        return blocks
    }

    private nonisolated func skipHTMLComment(in slice: ArraySlice<String>, from start: Int) -> Int {
        var idx = start
        while idx < slice.endIndex {
            if slice[idx].contains("-->") {
                return idx + 1
            }
            idx += 1
        }
        return slice.endIndex
    }

    // MARK: - Fences & Math

    private nonisolated func parseFenceOpening(_ line: String) -> (char: Character, length: Int, language: String?)? {
        let stripped = stripUpToThreeLeadingSpaces(line)
        guard let first = stripped.first, first == "`" || first == "~" else { return nil }

        var count = 0
        var idx = stripped.startIndex
        while idx < stripped.endIndex && stripped[idx] == first {
            count += 1
            idx = stripped.index(after: idx)
        }
        guard count >= 3 else { return nil }

        let info = String(stripped[idx...]).trimmingCharacters(in: .whitespaces)
        // Backtick fence info string cannot contain backticks per CommonMark.
        if first == "`" && info.contains("`") {
            return nil
        }
        let lang = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return (first, count, lang?.isEmpty == true ? nil : lang)
    }

    private nonisolated func consumeFencedCode(
        in slice: ArraySlice<String>,
        from start: Int,
        fenceChar: Character,
        fenceLength: Int
    ) -> (String, Int) {
        var collected: [String] = []
        var idx = start
        while idx < slice.endIndex {
            let line = slice[idx]
            let stripped = stripUpToThreeLeadingSpaces(line)
            if isClosingFence(stripped, char: fenceChar, minLength: fenceLength) {
                return (collected.joined(separator: "\n"), idx + 1)
            }
            collected.append(line)
            idx += 1
        }
        return (collected.joined(separator: "\n"), slice.endIndex)
    }

    private nonisolated func isClosingFence(_ stripped: String, char: Character, minLength: Int) -> Bool {
        var count = 0
        var idx = stripped.startIndex
        while idx < stripped.endIndex && stripped[idx] == char {
            count += 1
            idx = stripped.index(after: idx)
        }
        guard count >= minLength else { return false }
        return stripped[idx...].trimmingCharacters(in: .whitespaces).isEmpty
    }

    private nonisolated func consumeMathBlock(in slice: ArraySlice<String>, from start: Int) -> (String, Int) {
        let firstTrimmed = slice[start].trimmingCharacters(in: .whitespaces)
        var collected: [String] = []
        if firstTrimmed.count > 2 {
            collected.append(String(firstTrimmed.dropFirst(2)))
        }
        var idx = start + 1
        while idx < slice.endIndex {
            let line = slice[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "$$" {
                return (collected.joined(separator: "\n"), idx + 1)
            }
            if trimmed.hasSuffix("$$") && trimmed.count >= 2 {
                let tail = String(trimmed.dropLast(2))
                if !tail.isEmpty { collected.append(tail) }
                return (collected.joined(separator: "\n"), idx + 1)
            }
            collected.append(line)
            idx += 1
        }
        return (collected.joined(separator: "\n"), slice.endIndex)
    }

    // MARK: - Headings & Thematic Breaks

    private nonisolated func parseATXHeading(_ line: String) -> (level: Int, content: String)? {
        let stripped = stripUpToThreeLeadingSpaces(line)
        guard stripped.first == "#" else { return nil }

        var level = 0
        var idx = stripped.startIndex
        while idx < stripped.endIndex && stripped[idx] == "#" {
            level += 1
            idx = stripped.index(after: idx)
        }
        guard (1...6).contains(level) else { return nil }

        if idx < stripped.endIndex && stripped[idx] != " " && stripped[idx] != "\t" {
            return nil
        }

        var content = String(stripped[idx...]).trimmingCharacters(in: .whitespaces)
        // Strip optional closing ### sequence preceded by whitespace
        while content.hasSuffix("#") {
            let withoutHash = content.dropLast()
            if withoutHash.isEmpty || withoutHash.last == " " || withoutHash.last == "\t" || withoutHash.last == "#" {
                // Only strip trailing hashes if there is whitespace before the run (or whole line is hashes)
                let trimmedEnd = content.reversed().drop(while: { $0 == "#" })
                if trimmedEnd.isEmpty {
                    content = ""
                    break
                } else if trimmedEnd.first == " " || trimmedEnd.first == "\t" {
                    content = String(trimmedEnd.reversed()).trimmingCharacters(in: .whitespaces)
                    break
                } else {
                    break
                }
            } else {
                break
            }
        }
        return (level, content)
    }

    private nonisolated func parseSetextUnderline(_ line: String) -> Int? {
        let stripped = stripUpToThreeLeadingSpaces(line).trimmingCharacters(in: .whitespaces)
        guard let first = stripped.first, first == "=" || first == "-" else { return nil }
        guard stripped.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private nonisolated func isThematicBreak(_ line: String) -> Bool {
        let stripped = stripUpToThreeLeadingSpaces(line)
        let compact = stripped.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    // MARK: - Blockquotes & Callouts

    private nonisolated func isBlockquoteLine(_ line: String) -> Bool {
        stripUpToThreeLeadingSpaces(line).first == ">"
    }

    private nonisolated func stripQuoteMarker(_ line: String) -> String {
        let stripped = stripUpToThreeLeadingSpaces(line)
        guard stripped.first == ">" else { return line }
        var rest = stripped.dropFirst()
        if rest.first == " " || rest.first == "\t" {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    private nonisolated func consumeBlockquote(
        in slice: ArraySlice<String>,
        lineNumbers: ArraySlice<Int>,
        from start: Int,
        blockID: String,
        headingCounts: inout [String: Int]
    ) -> (MarkdownBlock, Int) {
        var innerLines: [String] = []
        var innerLineNums: [Int] = []
        var idx = start

        while idx < slice.endIndex {
            let line = slice[idx]
            if isBlockquoteLine(line) {
                innerLines.append(stripQuoteMarker(line))
                innerLineNums.append(lineNumbers[idx])
                idx += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            } else if !startsBlockConstruct(line) && !innerLines.isEmpty && !innerLines.last!.trimmingCharacters(in: .whitespaces).isEmpty {
                // Lazy continuation line
                innerLines.append(line)
                innerLineNums.append(lineNumbers[idx])
                idx += 1
            } else {
                break
            }
        }

        var alertKind: CalloutKind?
        var customTitle: String?

        if let first = innerLines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[!"), let closeIdx = trimmed.firstIndex(of: "]") {
                let markerStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
                let marker = String(trimmed[markerStart..<closeIdx])
                if let kind = CalloutKind(marker: marker) {
                    alertKind = kind
                    let trailing = String(trimmed[trimmed.index(after: closeIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !trailing.isEmpty {
                        customTitle = trailing
                    }
                    innerLines.removeFirst()
                    innerLineNums.removeFirst()
                }
            }
        }

        let innerBlocks = parseBlocks(
            from: innerLines[...],
            lineNumbers: innerLineNums[...],
            idPrefix: "\(blockID)-q",
            headingCounts: &headingCounts
        )
        return (.blockquote(id: blockID, alert: alertKind, titleOverride: customTitle, blocks: innerBlocks), idx)
    }

    // MARK: - GFM Tables

    private nonisolated func tryConsumeTable(
        in slice: ArraySlice<String>,
        from start: Int,
        blockID: String
    ) -> (MarkdownBlock, Int)? {
        guard start + 1 < slice.endIndex else { return nil }
        let headerLine = slice[start]
        let delimLine = slice[start + 1]

        guard headerLine.contains("|") else { return nil }
        guard let alignments = parseTableDelimiterRow(delimLine) else { return nil }

        let rawHeaders = splitTableRow(headerLine)
        guard !rawHeaders.isEmpty, rawHeaders.count == alignments.count else { return nil }

        let headers = rawHeaders.map { parseInlines($0) }
        var rows: [[[MarkdownInline]]] = []
        var idx = start + 2

        while idx < slice.endIndex {
            let line = slice[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || startsNonTableBlock(line) || !line.contains("|") {
                break
            }
            var cells = splitTableRow(line).map { parseInlines($0) }
            if cells.count < headers.count {
                cells.append(contentsOf: Array(repeating: [], count: headers.count - cells.count))
            } else if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            }
            rows.append(cells)
            idx += 1
        }

        return (.table(id: blockID, headers: headers, alignments: alignments, rows: rows), idx)
    }

    private nonisolated func parseTableDelimiterRow(_ line: String) -> [TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") && trimmed.contains("|") else { return nil }

        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return nil }

        var alignments: [TableAlignment] = []
        for cell in cells {
            let s = cell.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            let startsColon = s.hasPrefix(":")
            let endsColon = s.hasSuffix(":")
            let middle = s.dropFirst(startsColon ? 1 : 0).dropLast(endsColon ? 1 : 0)
            guard !middle.isEmpty, middle.allSatisfy({ $0 == "-" }) else { return nil }

            if startsColon && endsColon {
                alignments.append(.center)
            } else if endsColon {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }
        return alignments
    }

    private nonisolated func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") {
            trimmed.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var inCode = false
        var backtickRun = 0
        var idx = trimmed.startIndex

        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ch == "\\" {
                let next = trimmed.index(after: idx)
                if next < trimmed.endIndex && trimmed[next] == "|" {
                    current.append("|")
                    idx = trimmed.index(after: next)
                    continue
                }
            }
            if ch == "`" {
                var runEnd = idx
                var count = 0
                while runEnd < trimmed.endIndex && trimmed[runEnd] == "`" {
                    count += 1
                    runEnd = trimmed.index(after: runEnd)
                }
                if !inCode {
                    inCode = true
                    backtickRun = count
                } else if count == backtickRun {
                    inCode = false
                    backtickRun = 0
                }
                current.append(contentsOf: trimmed[idx..<runEnd])
                idx = runEnd
                continue
            }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            idx = trimmed.index(after: idx)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Lists

    private struct ListMarkerInfo {
        let indent: Int
        let ordered: Bool
        let startNumber: Int
        let contentOffset: Int
        let checked: Bool?
        let content: String
    }

    private nonisolated func parseListMarker(_ line: String) -> ListMarkerInfo? {
        let indent = leadingSpaceCount(line)
        let afterIndent = String(line.dropFirst(indent))

        // Unordered: -, *, + followed by space or tab
        if let first = afterIndent.first, first == "-" || first == "*" || first == "+" {
            let rest = afterIndent.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return nil }
            let rawContent = String(rest.dropFirst()).trimmingCharacters(in: .init(charactersIn: " "))
            let (checked, finalContent) = extractTaskCheckbox(from: String(rest.dropFirst()))
            _ = rawContent
            return ListMarkerInfo(
                indent: indent,
                ordered: false,
                startNumber: 1,
                contentOffset: indent + 2,
                checked: checked,
                content: finalContent
            )
        }

        // Ordered: digits + '.' or ')' followed by space or tab
        var digitCount = 0
        var digits = ""
        for ch in afterIndent {
            if ch.isASCII && ch.isNumber {
                digits.append(ch)
                digitCount += 1
            } else {
                break
            }
        }
        if digitCount > 0 && digitCount <= 9 {
            let afterDigits = afterIndent.dropFirst(digitCount)
            if let punct = afterDigits.first, punct == "." || punct == ")" {
                let afterPunct = afterDigits.dropFirst()
                if afterPunct.first == " " || afterPunct.first == "\t" {
                    let startNum = Int(digits) ?? 1
                    let (checked, finalContent) = extractTaskCheckbox(from: String(afterPunct.dropFirst()))
                    return ListMarkerInfo(
                        indent: indent,
                        ordered: true,
                        startNumber: startNum,
                        contentOffset: indent + digitCount + 2,
                        checked: checked,
                        content: finalContent
                    )
                }
            }
        }
        return nil
    }

    private nonisolated func extractTaskCheckbox(from content: String) -> (Bool?, String) {
        let trimmed = content.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("[ ] ") || trimmed == "[ ]" {
            let rest = trimmed.count > 3 ? String(trimmed.dropFirst(4)) : ""
            return (false, rest)
        }
        if trimmed.hasPrefix("[x] ") || trimmed.hasPrefix("[X] ") || trimmed == "[x]" || trimmed == "[X]" {
            let rest = trimmed.count > 3 ? String(trimmed.dropFirst(4)) : ""
            return (true, rest)
        }
        return (nil, String(trimmed))
    }

    private nonisolated func consumeList(
        in slice: ArraySlice<String>,
        lineNumbers: ArraySlice<Int>,
        from start: Int,
        blockID: String,
        headingCounts: inout [String: Int]
    ) -> (MarkdownBlock, Int) {
        guard let firstMarker = parseListMarker(slice[start]) else {
            return (.paragraph(id: blockID, inlines: []), start + 1)
        }

        let baseIndent = firstMarker.indent
        let ordered = firstMarker.ordered
        let startNumber = firstMarker.startNumber

        var items: [ListItem] = []
        var idx = start
        var itemIndex = 0

        while idx < slice.endIndex {
            let line = slice[idx]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Peek ahead to see if list continues at baseIndent
                var look = idx + 1
                while look < slice.endIndex && slice[look].trimmingCharacters(in: .whitespaces).isEmpty {
                    look += 1
                }
                if look < slice.endIndex,
                   !isThematicBreak(slice[look]),
                   let nextMarker = parseListMarker(slice[look]),
                   nextMarker.indent <= baseIndent + 1 && nextMarker.ordered == ordered {
                    idx = look
                    continue
                }
                break
            }

            if isThematicBreak(line) { break }

            guard let marker = parseListMarker(line),
                  marker.indent <= baseIndent + 1,
                  marker.ordered == ordered else {
                break
            }

            let sourceLine = lineNumbers[idx]
            var primaryLines: [String] = [marker.content]
            var childLines: [String] = []
            var childLineNums: [Int] = []
            idx += 1

            while idx < slice.endIndex {
                let nextLine = slice[idx]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)

                if nextTrimmed.isEmpty {
                    // Check if indented child block follows blank line
                    var look = idx + 1
                    while look < slice.endIndex && slice[look].trimmingCharacters(in: .whitespaces).isEmpty {
                        look += 1
                    }
                    if look < slice.endIndex && leadingSpaceCount(slice[look]) >= marker.contentOffset {
                        childLines.append("")
                        childLineNums.append(lineNumbers[idx])
                        idx += 1
                        continue
                    } else {
                        break
                    }
                }

                if isThematicBreak(nextLine) { break }

                let nextIndent = leadingSpaceCount(nextLine)
                if let subMarker = parseListMarker(nextLine) {
                    if subMarker.indent <= baseIndent + 1 {
                        // Next sibling item (or different list type)
                        break
                    }
                    // Indented sub-list belongs to childLines
                    childLines.append(stripIndent(nextLine, count: min(nextIndent, marker.contentOffset)))
                    childLineNums.append(lineNumbers[idx])
                    idx += 1
                    continue
                }

                if nextIndent >= marker.contentOffset {
                    let dedented = stripIndent(nextLine, count: marker.contentOffset)
                    if childLines.isEmpty && !startsBlockConstruct(dedented) {
                        primaryLines.append(dedented.trimmingCharacters(in: .whitespaces))
                    } else {
                        childLines.append(dedented)
                        childLineNums.append(lineNumbers[idx])
                    }
                    idx += 1
                    continue
                }

                // Lazy continuation of primary item text if non-block line
                if childLines.isEmpty && !startsBlockConstruct(nextLine) {
                    primaryLines.append(nextTrimmed)
                    idx += 1
                } else {
                    break
                }
            }

            let itemID = "\(blockID)-i\(itemIndex)"
            itemIndex += 1
            let inlines = parseInlines(primaryLines.joined(separator: "\n"))
            let children: [MarkdownBlock] = childLines.isEmpty
                ? []
                : parseBlocks(
                    from: childLines[...],
                    lineNumbers: childLineNums[...],
                    idPrefix: "\(itemID)-c",
                    headingCounts: &headingCounts
                )

            items.append(
                ListItem(
                    id: itemID,
                    inlines: inlines,
                    checked: marker.checked,
                    sourceLine: sourceLine,
                    children: children
                )
            )
        }

        return (.list(id: blockID, ordered: ordered, startIndex: startNumber, items: items), idx)
    }

    // MARK: - Paragraphs & Setext Headings

    private nonisolated func consumeParagraphOrSetextHeading(
        in slice: ArraySlice<String>,
        from start: Int,
        blockID: String,
        headingCounts: inout [String: Int]
    ) -> (MarkdownBlock, Int) {
        var lines: [String] = [slice[start]]
        var idx = start + 1

        while idx < slice.endIndex {
            let line = slice[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                break
            }

            if let setextLevel = parseSetextUnderline(line) {
                let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                let inlines = parseInlines(text)
                let plain = inlines.plainText
                let anchor = uniqueAnchor(for: plain, counts: &headingCounts)
                return (.heading(id: blockID, level: setextLevel, anchor: anchor, inlines: inlines, plainText: plain), idx + 1)
            }

            if startsParagraphInterruptingBlock(line) ||
                (idx + 1 < slice.endIndex && line.contains("|") && parseTableDelimiterRow(slice[idx + 1]) != nil) {
                break
            }

            lines.append(line)
            idx += 1
        }

        // Check standalone image paragraph: single image syntax covering entire paragraph
        if lines.count == 1 {
            let trimmed = lines[0].trimmingCharacters(in: .whitespaces)
            let parsed = parseInlines(trimmed)
            if parsed.count == 1, case .image(let alt, let url) = parsed[0] {
                return (.imageBlock(id: blockID, alt: alt, url: url), idx)
            }
        }

        let inlines = parseInlines(lines.joined(separator: "\n"))
        return (.paragraph(id: blockID, inlines: inlines), idx)
    }

    private nonisolated func startsBlockConstruct(_ line: String) -> Bool {
        startsParagraphInterruptingBlock(line) || parseListMarker(line) != nil
    }

    private nonisolated func startsNonTableBlock(_ line: String) -> Bool {
        startsParagraphInterruptingBlock(line) || parseListMarker(line) != nil
    }

    private nonisolated func startsParagraphInterruptingBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<!--") { return true }
        if parseFenceOpening(line) != nil { return true }
        if trimmed.hasPrefix("$$") { return true }
        if parseATXHeading(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if isBlockquoteLine(line) { return true }
        if parseListMarker(line) != nil { return true }
        return false
    }

    // MARK: - Inline Parsing

    nonisolated func parseInlines(_ input: String) -> [MarkdownInline] {
        guard !input.isEmpty else { return [] }
        return parseInlineRange(input[input.startIndex..<input.endIndex])
    }

    private nonisolated func parseInlineRange(_ slice: Substring) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var textBuffer = ""
        var idx = slice.startIndex

        func flushText() {
            if !textBuffer.isEmpty {
                result.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        while idx < slice.endIndex {
            let ch = slice[idx]

            // Newlines -> hardBreak (2+ trailing spaces or trailing '\') or softBreak
            if ch == "\n" {
                if textBuffer.hasSuffix("\\") {
                    textBuffer.removeLast()
                    flushText()
                    result.append(.hardBreak)
                } else if textBuffer.hasSuffix("  ") {
                    while textBuffer.hasSuffix(" ") {
                        textBuffer.removeLast()
                    }
                    flushText()
                    result.append(.hardBreak)
                } else {
                    flushText()
                    result.append(.softBreak)
                }
                idx = slice.index(after: idx)
                continue
            }

            // Backslash escape for ASCII punctuation
            if ch == "\\" {
                let next = slice.index(after: idx)
                if next < slice.endIndex && isASCIIPunctuation(slice[next]) {
                    textBuffer.append(slice[next])
                    idx = slice.index(after: next)
                    continue
                }
            }

            // Inline HTML <br> / <br/> / <br />
            if ch == "<" {
                if let brEnd = matchLineBreakTag(in: slice, from: idx) {
                    flushText()
                    result.append(.hardBreak)
                    idx = brEnd
                    continue
                }
                if let auto = parseAngleBracketAutolink(in: slice, from: idx) {
                    flushText()
                    result.append(.link(label: [.text(auto.display)], destination: auto.destination))
                    idx = auto.endIndex
                    continue
                }
            }

            // Inline code span (`code` or ``code``)
            if ch == "`" {
                if let codeSpan = parseInlineCodeSpan(in: slice, from: idx) {
                    flushText()
                    result.append(.code(codeSpan.code))
                    idx = codeSpan.endIndex
                    continue
                } else {
                    var runEnd = idx
                    while runEnd < slice.endIndex && slice[runEnd] == "`" {
                        textBuffer.append("`")
                        runEnd = slice.index(after: runEnd)
                    }
                    idx = runEnd
                    continue
                }
            }

            // Image ![alt](url)
            if ch == "!" {
                let next = slice.index(after: idx)
                if next < slice.endIndex && slice[next] == "[",
                   let parsed = parseLinkOrImage(in: slice, bracketStart: next, isImage: true) {
                    flushText()
                    result.append(.image(alt: parsed.labelRaw, url: parsed.destination))
                    idx = parsed.endIndex
                    continue
                }
            }

            // Link [label](url)
            if ch == "[" {
                if let parsed = parseLinkOrImage(in: slice, bracketStart: idx, isImage: false) {
                    flushText()
                    let labelInlines = parseInlineRange(parsed.labelSlice)
                    result.append(.link(label: labelInlines, destination: parsed.destination))
                    idx = parsed.endIndex
                    continue
                }
            }

            // Emphasis / Strong / Strikethrough / Highlight
            if ch == "*" || ch == "_" || ch == "~" || ch == "=" {
                if let delim = parseDelimitedInline(in: slice, from: idx, marker: ch) {
                    flushText()
                    result.append(contentsOf: delim.inlines)
                    idx = delim.endIndex
                    continue
                }
            }

            // Bare URL autolink (http:// or https://)
            if ch == "h" && (slice[idx...].hasPrefix("https://") || slice[idx...].hasPrefix("http://")) {
                let canStart = idx == slice.startIndex || !isWordChar(slice[slice.index(before: idx)])
                if canStart, let bare = parseBareURL(in: slice, from: idx) {
                    flushText()
                    result.append(.link(label: [.text(bare.url)], destination: bare.url))
                    idx = bare.endIndex
                    continue
                }
            }

            textBuffer.append(ch)
            idx = slice.index(after: idx)
        }

        flushText()
        return result
    }

    private nonisolated func parseInlineCodeSpan(in slice: Substring, from start: String.Index) -> (code: String, endIndex: String.Index)? {
        var openEnd = start
        var openCount = 0
        while openEnd < slice.endIndex && slice[openEnd] == "`" {
            openCount += 1
            openEnd = slice.index(after: openEnd)
        }

        var cursor = openEnd
        while cursor < slice.endIndex {
            if slice[cursor] == "`" {
                var closeEnd = cursor
                var closeCount = 0
                while closeEnd < slice.endIndex && slice[closeEnd] == "`" {
                    closeCount += 1
                    closeEnd = slice.index(after: closeEnd)
                }
                if closeCount == openCount {
                    var content = String(slice[openEnd..<cursor])
                        .replacingOccurrences(of: "\n", with: " ")
                    if content.count >= 2 && content.hasPrefix(" ") && content.hasSuffix(" ") && !content.allSatisfy({ $0 == " " }) {
                        content.removeFirst()
                        content.removeLast()
                    }
                    return (content, closeEnd)
                }
                cursor = closeEnd
            } else {
                cursor = slice.index(after: cursor)
            }
        }
        return nil
    }

    private nonisolated func parseLinkOrImage(
        in slice: Substring,
        bracketStart: String.Index,
        isImage: Bool
    ) -> (labelSlice: Substring, labelRaw: String, destination: String, endIndex: String.Index)? {
        var cursor = slice.index(after: bracketStart)
        var bracketDepth = 1
        var labelEnd: String.Index?

        while cursor < slice.endIndex {
            let c = slice[cursor]
            if c == "\\" {
                let next = slice.index(after: cursor)
                cursor = next < slice.endIndex ? slice.index(after: next) : slice.endIndex
                continue
            }
            if c == "`" {
                if let codeSpan = parseInlineCodeSpan(in: slice, from: cursor) {
                    cursor = codeSpan.endIndex
                    continue
                }
            }
            if c == "[" {
                bracketDepth += 1
            } else if c == "]" {
                bracketDepth -= 1
                if bracketDepth == 0 {
                    labelEnd = cursor
                    break
                }
            }
            cursor = slice.index(after: cursor)
        }

        guard let closeBracket = labelEnd else { return nil }
        let afterBracket = slice.index(after: closeBracket)
        guard afterBracket < slice.endIndex && slice[afterBracket] == "(" else { return nil }

        let labelSlice = slice[slice.index(after: bracketStart)..<closeBracket]
        var destCursor = slice.index(after: afterBracket)

        // Skip leading spaces inside (...)
        while destCursor < slice.endIndex && (slice[destCursor] == " " || slice[destCursor] == "\t") {
            destCursor = slice.index(after: destCursor)
        }
        guard destCursor < slice.endIndex else { return nil }

        var destination = ""
        if slice[destCursor] == "<" {
            let angleStart = slice.index(after: destCursor)
            guard let angleEnd = slice[angleStart...].firstIndex(of: ">") else { return nil }
            destination = String(slice[angleStart..<angleEnd])
            destCursor = slice.index(after: angleEnd)
        } else {
            var parenDepth = 0
            let destStart = destCursor
            while destCursor < slice.endIndex {
                let c = slice[destCursor]
                if c == "\\" {
                    let next = slice.index(after: destCursor)
                    destCursor = next < slice.endIndex ? slice.index(after: next) : slice.endIndex
                    continue
                }
                if c == "(" {
                    parenDepth += 1
                } else if c == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                } else if c == " " || c == "\t" || c == "\n" {
                    break
                }
                destCursor = slice.index(after: destCursor)
            }
            destination = String(slice[destStart..<destCursor])
        }

        // Skip optional title up to closing ')'
        while destCursor < slice.endIndex && slice[destCursor] != ")" {
            let c = slice[destCursor]
            if c == "\n" { return nil }
            if c == "\"" || c == "'" {
                let quote = c
                destCursor = slice.index(after: destCursor)
                while destCursor < slice.endIndex && slice[destCursor] != quote {
                    if slice[destCursor] == "\\" {
                        let n = slice.index(after: destCursor)
                        destCursor = n < slice.endIndex ? slice.index(after: n) : slice.endIndex
                    } else {
                        destCursor = slice.index(after: destCursor)
                    }
                }
                if destCursor < slice.endIndex {
                    destCursor = slice.index(after: destCursor)
                }
            } else {
                destCursor = slice.index(after: destCursor)
            }
        }

        guard destCursor < slice.endIndex && slice[destCursor] == ")" else { return nil }
        let cleanDest = destination.trimmingCharacters(in: .whitespaces)
        return (labelSlice, String(labelSlice), cleanDest, slice.index(after: destCursor))
    }

    private nonisolated func parseDelimitedInline(
        in slice: Substring,
        from start: String.Index,
        marker: Character
    ) -> (inlines: [MarkdownInline], endIndex: String.Index)? {
        var runEnd = start
        var runCount = 0
        while runEnd < slice.endIndex && slice[runEnd] == marker && runCount < 3 {
            runCount += 1
            runEnd = slice.index(after: runEnd)
        }

        if (marker == "~" || marker == "=") && runCount != 2 {
            return nil
        }

        // Intraword underscore protection: `foo_bar_baz` should NOT italicize `bar`
        if marker == "_" && start > slice.startIndex {
            let prev = slice[slice.index(before: start)]
            if isWordChar(prev) { return nil }
        }

        // Must not immediately be followed by whitespace
        guard runEnd < slice.endIndex && !slice[runEnd].isWhitespace else { return nil }

        // Search for closing run of exact length `runCount`
        var cursor = runEnd
        while cursor < slice.endIndex {
            let ch = slice[cursor]
            if ch == "\\" {
                let next = slice.index(after: cursor)
                cursor = next < slice.endIndex ? slice.index(after: next) : slice.endIndex
                continue
            }
            if ch == "`" {
                if let codeSpan = parseInlineCodeSpan(in: slice, from: cursor) {
                    cursor = codeSpan.endIndex
                    continue
                }
            }
            if ch == marker {
                var closeEnd = cursor
                var closeCount = 0
                while closeEnd < slice.endIndex && slice[closeEnd] == marker && closeCount < runCount {
                    closeCount += 1
                    closeEnd = slice.index(after: closeEnd)
                }
                if closeCount == runCount {
                    let prevChar = slice[slice.index(before: cursor)]
                    let canCloseWhitespace = !prevChar.isWhitespace
                    let canCloseIntraword = marker != "_" || closeEnd == slice.endIndex || !isWordChar(slice[closeEnd])
                    if canCloseWhitespace && canCloseIntraword {
                        let inner = slice[runEnd..<cursor]
                        let children = parseInlineRange(inner)
                        let wrapped: [MarkdownInline]
                        switch (marker, runCount) {
                        case ("*", 3), ("_", 3):
                            wrapped = [.strong([.emphasis(children)])]
                        case ("*", 2), ("_", 2):
                            wrapped = [.strong(children)]
                        case ("*", 1), ("_", 1):
                            wrapped = [.emphasis(children)]
                        case ("~", 2):
                            wrapped = [.strikethrough(children)]
                        case ("=", 2):
                            wrapped = [.highlight(children)]
                        default:
                            return nil
                        }
                        return (wrapped, closeEnd)
                    }
                }
                cursor = closeEnd
                continue
            }
            cursor = slice.index(after: cursor)
        }

        return nil
    }

    private nonisolated func matchLineBreakTag(in slice: Substring, from start: String.Index) -> String.Index? {
        let rem = slice[start...]
        for prefix in ["<br>", "<br/>", "<br />", "<BR>", "<BR/>", "<BR />"] {
            if rem.hasPrefix(prefix) {
                return slice.index(start, offsetBy: prefix.count)
            }
        }
        return nil
    }

    private nonisolated func parseAngleBracketAutolink(
        in slice: Substring,
        from start: String.Index
    ) -> (display: String, destination: String, endIndex: String.Index)? {
        let afterOpen = slice.index(after: start)
        guard let close = slice[afterOpen...].firstIndex(of: ">") else { return nil }
        let inner = String(slice[afterOpen..<close])
        guard !inner.contains(" ") && !inner.contains("\n") else { return nil }

        if inner.hasPrefix("http://") || inner.hasPrefix("https://") {
            return (inner, inner, slice.index(after: close))
        }
        if inner.contains("@") && !inner.contains(":") {
            return (inner, "mailto:\(inner)", slice.index(after: close))
        }
        return nil
    }

    private nonisolated func parseBareURL(in slice: Substring, from start: String.Index) -> (url: String, endIndex: String.Index)? {
        var cursor = start
        while cursor < slice.endIndex {
            let ch = slice[cursor]
            if ch.isWhitespace || ch == "<" || ch == ">" || ch == "\"" || ch == "'" {
                break
            }
            cursor = slice.index(after: cursor)
        }
        // Trim trailing punctuation commonly adjacent to URLs in prose
        while cursor > start {
            let last = slice[slice.index(before: cursor)]
            if last == "." || last == "," || last == ";" || last == ":" || last == "!" || last == "?" {
                cursor = slice.index(before: cursor)
            } else if last == ")" {
                let candidate = slice[start..<cursor]
                let openCount = candidate.filter { $0 == "(" }.count
                let closeCount = candidate.filter { $0 == ")" }.count
                if closeCount > openCount {
                    cursor = slice.index(before: cursor)
                } else {
                    break
                }
            } else {
                break
            }
        }
        let url = String(slice[start..<cursor])
        guard url.count > 8 else { return nil }
        return (url, cursor)
    }

    // MARK: - Helpers & Stats

    private nonisolated func stripUpToThreeLeadingSpaces(_ line: String) -> String {
        var dropped = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == " " && dropped < 3 {
            dropped += 1
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }

    private nonisolated func leadingSpaceCount(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private nonisolated func stripIndent(_ line: String, count: Int) -> String {
        var remaining = count
        var idx = line.startIndex
        while idx < line.endIndex && remaining > 0 {
            if line[idx] == " " {
                remaining -= 1
                idx = line.index(after: idx)
            } else if line[idx] == "\t" {
                remaining -= 4
                idx = line.index(after: idx)
            } else {
                break
            }
        }
        return String(line[idx...])
    }

    private nonisolated func isASCIIPunctuation(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        let v = scalar.value
        return (0x21...0x2F).contains(v) || (0x3A...0x40).contains(v) || (0x5B...0x60).contains(v) || (0x7B...0x7E).contains(v)
    }

    private nonisolated func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    private nonisolated func uniqueAnchor(for text: String, counts: inout [String: Int]) -> String {
        var slug = ""
        var lastWasHyphen = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasHyphen = false
            } else if ch == " " || ch == "-" || ch == "_" {
                if !lastWasHyphen && !slug.isEmpty {
                    slug.append("-")
                    lastWasHyphen = true
                }
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "section" }

        let existing = counts[slug, default: 0]
        counts[slug] = existing + 1
        return existing == 0 ? slug : "\(slug)-\(existing)"
    }

    private nonisolated func collectStatsAndHeadings(
        from blocks: [MarkdownBlock],
        headings: inout [HeadingEntry],
        codeBlockCount: inout Int
    ) {
        for block in blocks {
            switch block {
            case .heading(let id, let level, let anchor, _, let plainText):
                headings.append(HeadingEntry(id: id, level: level, text: plainText, anchor: anchor))
            case .codeBlock:
                codeBlockCount += 1
            case .blockquote(_, _, _, let inner):
                collectStatsAndHeadings(from: inner, headings: &headings, codeBlockCount: &codeBlockCount)
            case .list(_, _, _, let items):
                for item in items {
                    collectStatsAndHeadings(from: item.children, headings: &headings, codeBlockCount: &codeBlockCount)
                }
            default:
                break
            }
        }
    }

    private nonisolated func computeStats(
        rawSource: String,
        lineCount: Int,
        headingCount: Int,
        codeBlockCount: Int
    ) -> DocumentStats {
        var latinWords = 0
        var cjkChars = 0
        var inLatinWord = false

        for scalar in rawSource.unicodeScalars {
            let v = scalar.value
            let isCJK = (0x3040...0x30FF).contains(v) || // Hiragana & Katakana
                        (0x4E00...0x9FFF).contains(v) || // CJK Unified Ideographs
                        (0xAC00...0xD7AF).contains(v)    // Hangul
            if isCJK {
                if inLatinWord {
                    latinWords += 1
                    inLatinWord = false
                }
                cjkChars += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                inLatinWord = true
            } else {
                if inLatinWord {
                    latinWords += 1
                    inLatinWord = false
                }
            }
        }
        if inLatinWord { latinWords += 1 }

        // Reading speed heuristic: ~220 English words/min, ~500 Japanese chars/min
        let totalUnits = latinWords + cjkChars
        let minutesFloat = Double(latinWords) / 220.0 + Double(cjkChars) / 500.0
        let estimatedMinutes = max(1, Int(ceil(minutesFloat)))

        return DocumentStats(
            wordCount: totalUnits,
            characterCount: rawSource.count,
            lineCount: lineCount,
            estimatedReadingMinutes: estimatedMinutes,
            headingCount: headingCount,
            codeBlockCount: codeBlockCount
        )
    }
}
