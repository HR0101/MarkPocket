import Foundation
import SwiftUI

struct CodeThemePalette: Sendable {
    let text: Color
    let comment: Color
    let keyword: Color
    let string: Color
    let number: Color
    let typeName: Color
    let property: Color

    static let light = CodeThemePalette(
        text: Color(red: 0.14, green: 0.16, blue: 0.21),
        comment: Color(red: 0.44, green: 0.49, blue: 0.56),
        keyword: Color(red: 0.68, green: 0.14, blue: 0.49),
        string: Color(red: 0.72, green: 0.24, blue: 0.14),
        number: Color(red: 0.11, green: 0.42, blue: 0.73),
        typeName: Color(red: 0.36, green: 0.22, blue: 0.69),
        property: Color(red: 0.08, green: 0.48, blue: 0.44)
    )

    static let dark = CodeThemePalette(
        text: Color(red: 0.90, green: 0.92, blue: 0.96),
        comment: Color(red: 0.52, green: 0.58, blue: 0.68),
        keyword: Color(red: 0.99, green: 0.48, blue: 0.69),
        string: Color(red: 0.99, green: 0.56, blue: 0.44),
        number: Color(red: 0.55, green: 0.78, blue: 1.00),
        typeName: Color(red: 0.67, green: 0.85, blue: 0.69),
        property: Color(red: 0.48, green: 0.87, blue: 0.82)
    )
}

/// Lightweight token-based syntax highlighter for fenced code blocks.
struct SyntaxHighlighter: Sendable {

    nonisolated init() {}

    nonisolated func highlight(
        code: String,
        language: String?,
        isDark: Bool
    ) -> AttributedString {
        let palette = isDark ? CodeThemePalette.dark : CodeThemePalette.light
        var result = AttributedString(code)
        result.foregroundColor = palette.text

        // Avoid expensive scanning on massive generated blobs (> 20 KB)
        guard code.utf8.count <= 20_000 else {
            return result
        }

        let lang = (language ?? "").lowercased()
        let keywords = keywordSet(for: lang)

        // Apply spans in priority order: numbers -> types -> keywords -> strings -> comments
        // Later passes override overlapping colors so comments & strings always win cleanly.
        applyPattern(#"\b0x[0-9a-fA-F_]+\b|\b\d+(?:\.\d+)?\b"#, color: palette.number, in: code, to: &result)
        applyPattern(#"\b[A-Z][A-Za-z0-9_]*\b"#, color: palette.typeName, in: code, to: &result)

        if !keywords.isEmpty {
            let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let kwPattern = #"(?<![A-Za-z0-9_])("# + escaped + #")(?![A-Za-z0-9_])"#
            applyPattern(kwPattern, color: palette.keyword, in: code, to: &result)
        }

        if lang == "json" || lang == "yaml" || lang == "yml" {
            applyPattern(#"(?m)^\s*[A-Za-z0-9_.-]+(?=\s*:)"#, color: palette.property, in: code, to: &result)
            applyPattern(#""(?:\\.|[^"\\])*"(?=\s*:)"#, color: palette.property, in: code, to: &result)
        }

        // Strings (double & single quoted)
        applyPattern(#""(?:\\.|[^"\\\n])*""#, color: palette.string, in: code, to: &result)
        applyPattern(#"'(?:\\.|[^'\\\n])*'"#, color: palette.string, in: code, to: &result)

        // Comments
        if usesHashComments(lang) {
            applyPattern(#"(?m)#.*$"#, color: palette.comment, in: code, to: &result)
        }
        if usesSlashComments(lang) {
            applyPattern(#"//.*$"#, options: [.anchorsMatchLines], color: palette.comment, in: code, to: &result)
            applyPattern(#"/\*[\s\S]*?\*/"#, color: palette.comment, in: code, to: &result)
        }
        if lang == "sql" {
            applyPattern(#"--.*$"#, options: [.anchorsMatchLines], color: palette.comment, in: code, to: &result)
        }

        return result
    }

    private nonisolated func applyPattern(
        _ pattern: String,
        options: NSRegularExpression.Options = [],
        color: Color,
        in source: String,
        to attributed: inout AttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)

        for match in matches {
            guard let stringRange = Range(match.range, in: source),
                  let attrStart = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let attrEnd = AttributedString.Index(stringRange.upperBound, within: attributed) else {
                continue
            }
            attributed[attrStart..<attrEnd].foregroundColor = color
        }
    }

    private nonisolated func usesHashComments(_ lang: String) -> Bool {
        ["py", "python", "sh", "bash", "zsh", "shell", "yaml", "yml", "rb", "ruby", "toml", "dockerfile", "makefile", ""].contains(lang)
    }

    private nonisolated func usesSlashComments(_ lang: String) -> Bool {
        ["swift", "js", "javascript", "ts", "typescript", "tsx", "jsx", "c", "cpp", "c++", "h", "hpp", "java", "kt", "kotlin", "go", "rs", "rust", "css", "scss", "jsonc", ""].contains(lang)
    }

    private nonisolated func keywordSet(for lang: String) -> [String] {
        switch lang {
        case "swift":
            return ["import", "struct", "class", "enum", "protocol", "extension", "actor", "func", "var", "let", "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "in", "return", "throw", "throws", "try", "catch", "async", "await", "nonisolated", "isolated", "private", "fileprivate", "internal", "public", "open", "static", "mutating", "init", "self", "Self", "nil", "true", "false", "some", "any", "where", "typealias", "associatedtype", "defer", "do", "break", "continue"]
        case "python", "py":
            return ["import", "from", "as", "def", "class", "return", "yield", "if", "elif", "else", "for", "while", "break", "continue", "in", "is", "not", "and", "or", "try", "except", "finally", "raise", "with", "pass", "lambda", "async", "await", "True", "False", "None", "self"]
        case "js", "javascript", "ts", "typescript", "jsx", "tsx":
            return ["import", "export", "from", "default", "const", "let", "var", "function", "return", "if", "else", "switch", "case", "for", "while", "of", "in", "break", "continue", "try", "catch", "finally", "throw", "async", "await", "class", "extends", "implements", "interface", "type", "enum", "new", "this", "true", "false", "null", "undefined"]
        case "sh", "bash", "zsh", "shell":
            return ["if", "then", "else", "elif", "fi", "for", "do", "done", "while", "case", "esac", "in", "function", "local", "export", "return", "exit", "true", "false", "echo", "cd", "ls", "grep", "git", "swift", "xcodebuild"]
        case "sql":
            return ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "JOIN", "INNER", "LEFT", "RIGHT", "ON", "GROUP", "BY", "ORDER", "ASC", "DESC", "LIMIT", "AS", "AND", "OR", "NOT", "NULL", "PRIMARY", "KEY", "select", "from", "where", "insert", "update", "delete", "create", "table", "join", "order", "by", "group", "limit"]
        case "go":
            return ["package", "import", "func", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "switch", "case", "default", "return", "go", "defer", "select", "chan", "map", "nil", "true", "false"]
        case "rs", "rust":
            return ["use", "mod", "pub", "fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "for", "in", "if", "else", "match", "loop", "while", "return", "async", "await", "self", "Self", "Some", "None", "Ok", "Err", "true", "false", "where"]
        case "json":
            return ["true", "false", "null"]
        case "yaml", "yml":
            return ["true", "false", "null", "yes", "no"]
        default:
            return ["import", "func", "def", "function", "class", "struct", "const", "let", "var", "if", "else", "for", "while", "return", "true", "false", "null", "nil"]
        }
    }
}
