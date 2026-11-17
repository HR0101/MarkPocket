import Testing
@testable import MarkPocket

struct MarkdownParserTests {
    private let parser = MarkdownParser()

    @Test func parsesYAMLFrontmatterAndHeadings() {
        let md = """
        ---
        title: "サンプル文書"
        author: Ryuto
        tags: [Swift, iOS, Markdown]
        ---

        # はじめに

        ## セクション 1

        ## セクション 1

        Setext H2
        ---------
        """
        let doc = parser.parse(md)

        #expect(doc.frontmatter.count == 3)
        #expect(doc.frontmatter[0].key == "title")
        #expect(doc.frontmatter[0].value == "サンプル文書")
        #expect(doc.frontmatter[2].value == "Swift, iOS, Markdown")

        #expect(doc.headings.count == 4)
        #expect(doc.headings[0].level == 1)
        #expect(doc.headings[0].text == "はじめに")
        #expect(doc.headings[1].anchor == "セクション-1")
        #expect(doc.headings[2].anchor == "セクション-1-1")
        #expect(doc.headings[3].level == 2)
        #expect(doc.headings[3].text == "Setext H2")
    }

    @Test func parsesCodeBlocksWithNestedFencesAndLanguages() {
        let md = """
        ````markdown
        # Nested
        ```swift
        let x = 1
        ```
        ````

        ~~~python
        def hello():
            return "world"
        ~~~
        """
        let doc = parser.parse(md)

        #expect(doc.blocks.count == 2)
        if case .codeBlock(_, let lang1, let code1) = doc.blocks[0] {
            #expect(lang1 == "markdown")
            #expect(code1.contains("```swift"))
        } else {
            Issue.record("Expected first block to be markdown codeBlock")
        }

        if case .codeBlock(_, let lang2, let code2) = doc.blocks[1] {
            #expect(lang2 == "python")
            #expect(code2.contains("def hello():"))
        } else {
            Issue.record("Expected second block to be python codeBlock")
        }
    }

    @Test func parsesGFMTablesWithAlignmentsAndEscapedPipes() {
        let md = """
        | Column A | Center | Right |
        | :--- | :---: | ---: |
        | `a | b` | **bold** | 100 |
        | escaped\\|pipe | ok | 200 |
        """
        let doc = parser.parse(md)

        #expect(doc.blocks.count == 1)
        guard case .table(_, let headers, let alignments, let rows) = doc.blocks[0] else {
            Issue.record("Expected table block")
            return
        }
        #expect(headers.count == 3)
        #expect(alignments == [.left, .center, .right])
        #expect(rows.count == 2)
        #expect(rows[0][0] == [.code("a | b")])
        #expect(rows[1][0].plainText == "escaped|pipe")
    }

    @Test func parsesCalloutsAndRegularBlockquotes() {
        let md = """
        > [!WARNING] 注意事項
        > この操作は元に戻せません。

        > 通常の引用文です。
        """
        let doc = parser.parse(md)

        #expect(doc.blocks.count == 2)
        if case .blockquote(_, let alert, let titleOverride, let inner) = doc.blocks[0] {
            #expect(alert == .warning)
            #expect(titleOverride == "注意事項")
            #expect(inner.count == 1)
        } else {
            Issue.record("Expected warning callout")
        }

        if case .blockquote(_, let alert, _, _) = doc.blocks[1] {
            #expect(alert == nil)
        } else {
            Issue.record("Expected standard blockquote")
        }
    }

    @Test func preservesIntrawordUnderscoresAndParsesRichInlines() {
        let md = "Use `my_func_name` or my_var_name with **bold**, *italic*, ~~strike~~, ==mark==, and [Wiki](https://en.wikipedia.org/wiki/Swift_(programming_language))."
        let doc = parser.parse(md)

        guard case .paragraph(_, let inlines) = doc.blocks.first else {
            Issue.record("Expected paragraph")
            return
        }

        let plain = inlines.plainText
        #expect(plain.contains("my_var_name"))
        #expect(inlines.contains(.code("my_func_name")))
        #expect(inlines.contains(.strong([.text("bold")])))
        #expect(inlines.contains(.emphasis([.text("italic")])))
        #expect(inlines.contains(.strikethrough([.text("strike")])))
        #expect(inlines.contains(.highlight([.text("mark")])))
        #expect(inlines.contains(.link(label: [.text("Wiki")], destination: "https://en.wikipedia.org/wiki/Swift_(programming_language)")))
    }

    @Test func parsesNestedTaskListsAndTracksExactSourceLines() {
        let md = """
        ---
        title: Tasks
        ---

        - [ ] Top task
          - [x] Nested done
        - [ ] Second top
        """
        let doc = parser.parse(md)

        guard case .list(_, let ordered, _, let items) = doc.blocks.first else {
            Issue.record("Expected list block")
            return
        }
        #expect(!ordered)
        #expect(items.count == 2)
        #expect(items[0].checked == false)
        #expect(items[0].sourceLine == 4)
        #expect(items[1].checked == false)
        #expect(items[1].sourceLine == 6)

        guard case .list(_, _, _, let nested)? = items[0].children.first else {
            Issue.record("Expected nested list")
            return
        }
        #expect(nested[0].checked == true)
        #expect(nested[0].sourceLine == 5)
    }

    @Test func findsSearchMatchesAndHighlightsCodeWithoutCrashing() {
        let md = """
        # Swift Guide

        Welcome to SwiftUI.

        ```swift
        // 日本語コメント Swift sample
        let greeting = "Hello, MarkPocket!"
        ```
        """
        let doc = parser.parse(md)
        let matches = doc.searchMatches(for: "swift")
        #expect(matches.count == 3)

        let codeMatches = doc.searchMatches(for: "MarkPocket")
        #expect(codeMatches.count == 1)

        let highlighter = SyntaxHighlighter()
        let attributed = highlighter.highlight(
            code: "// 日本語コメント\nlet greeting = \"Hello, MarkPocket!\"",
            language: "swift",
            isDark: true
        )
        #expect(String(attributed.characters).contains("greeting"))
    }
}
