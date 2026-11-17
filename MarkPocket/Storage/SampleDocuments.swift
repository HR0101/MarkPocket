import Foundation

enum SampleDocuments {
    static let guideFileName = "MarkPocket_Guide.md"
    static let cheatSheetFileName = "Markdown_CheatSheet.md"

    static let guideMarkdown = """
    ---
    title: MarkPocket ガイド
    author: MarkPocket
    tags: [Markdown, iOS, Guide]
    ---

    # MarkPocket ガイド

    **MarkPocket** は、手元の Markdown ファイルをスマートフォンで落ち着いて読むためのリーダーです。

    > [!TIP]
    > 右上の表示設定ボタンからテーマ（システム / ペーパー / セピア / ミッドナイト / OLED）、フォント（ゴシック / 明朝 / 等幅）、文字サイズを切り替えられます。

    ## 主な機能

    - [x] ファイルアプリ・iCloud Drive・AirDrop からの `.md` 直接読み込み
    - [x] フォルダ連携による複数ドキュメントの自動同期
    - [x] 見出しアウトライン（目次）ジャンプとページ内検索
    - [x] コードブロックのシンタックスハイライトとコピー
    - [x] GFM テーブルの横スクロール表示
    - [ ] 手元の `.md` ファイルを開く

    > [!NOTE]
    > この iPhone 内に保存されたファイルでは、タスクリストのチェックボックスをタップしてそのまま更新できます。

    ## コードブロック表示

    横幅の狭い画面でも崩れないよう、コードブロックは横スクロールと行番号・折り返し表示の切り替えに対応しています。

    ```swift
    import SwiftUI

    struct MarkdownSample: View {
        let title: String

        var body: some View {
            Label(title, systemImage: "doc.text")
                .font(.headline)
        }
    }
    ```

    ## テーブル表示

    | 機能 | 対応状況 | 備考 |
    | :--- | :---: | ---: |
    | 見出し・目次ジャンプ | 対応済み | H1 - H6 |
    | コールアウト (`[!NOTE]`) | 対応済み | 5 種類 |
    | 表の横スクロール | 対応済み | 左・中央・右寄せ |
    | 原文 / プレビュー切替 | 対応済み | 下部バーから切替 |

    ## 数式・引用・リンク

    > 「良いドキュメントは、読む環境が整ってこそ価値を発揮する。」

    $$
    E = mc^2 \\quad / \\quad \\sum_{i=1}^{n} x_i
    $$

    記法の一覧は [Markdown リファレンス](./Markdown_CheatSheet.md) を参照してください。
    """

    static let cheatSheetMarkdown = """
    ---
    title: Markdown リファレンス
    tags: [Reference, Syntax]
    ---

    # Markdown リファレンス

    よく使う Markdown 記法の一覧です。画面下部の `</>` ボタンから **原文** に切り替えると、元の記法と見比べることができます。

    ## 1. テキスト装飾

    - **太字**: `**太字**`
    - *斜体*: `*斜体*`
    - ~~打ち消し線~~: `~~打ち消し線~~`
    - ==ハイライト==: `==ハイライト==`
    - インラインコード: `` `let x = 42` ``

    ## 2. 見出し

    ```markdown
    # 見出し 1 (H1)
    ## 見出し 2 (H2)
    ### 見出し 3 (H3)
    ```

    ## 3. コールアウト

    > [!NOTE]
    > 補足情報やメモを記載します。

    > [!IMPORTANT]
    > 見落としてはいけない手順を示します。

    > [!WARNING]
    > 注意が必要な操作を伝えます。

    > [!CAUTION]
    > 破壊的な変更やデータ損失のリスクを示します。

    ## 4. リストとネスト

    1. 最初の手順
       - サブ項目の A
       - サブ項目の B
    2. 次の手順
       - [x] 完了したタスク
       - [ ] 未完了のタスク

    ---

    他のアプリでコピーしたテキストは、ライブラリ画面の「クリップボード」から直接表示できます。
    """
}
