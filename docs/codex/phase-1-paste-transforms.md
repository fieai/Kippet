# Phase 1 — 处理后粘贴 + 粘贴为指定格式

Read `AGENTS.md` first. This phase adds two related paste features. Both reuse the existing paste pipeline (`ShelfDelegate.paste(_:plainText:)` → `pasteWhenPrepared` → `ClipboardStore.copy`), so direct paste, focus handoff and the paste stack keep working unchanged.

## A. 粘贴过滤器 (text transforms)

New file `Sources/ClipShelf/PasteTransform.swift`, pure Swift (Foundation only):

```swift
enum PasteTransform: String, CaseIterable, Identifiable, Codable, Sendable {
    case trimWhitespace      // 去除首尾空白
    case collapseWhitespace  // 合并多余空白（每行内连续空白 → 一个空格，去掉每行首尾空白）
    case removeLineBreaks    // 合并为一行（换行 → 空格，再合并空白）
    case removeBlankLines    // 删除空行
    case uppercase           // 全部大写
    case lowercase           // 全部小写
    case capitalized         // 单词首字母大写
    case sortLines           // 按行排序（localizedStandardCompare）
    case dedupeLines         // 删除重复行（保留首次出现顺序）
    case jsonPretty          // JSON 格式化（2 空格缩进，sortedKeys 关闭，withoutEscapingSlashes）
    case jsonMinify          // JSON 压缩
    case cleanURL            // 清除链接追踪参数
    case urlEncode           // URL 编码（addingPercentEncoding .urlQueryAllowed 去掉 &=+?）
    case urlDecode           // URL 解码
    case base64Encode
    case base64Decode        // 结果必须是有效 UTF-8，否则失败
    var id: String { rawValue }
    var title: String        // Chinese labels from the comments above
    var section: Section     // .cleanup, .case, .lines, .developer — used to group the menu
    func apply(to text: String) -> String?   // nil = not applicable / failed (e.g. invalid JSON)
}
```

`cleanURL` works on every URL found in the text (use `NSDataDetector` link type), removing query items whose name matches: `utm_*`, `fbclid`, `gclid`, `dclid`, `msclkid`, `mc_cid`, `mc_eid`, `igshid`, `si` (only on youtube.com / youtu.be / open.spotify.com), `spm`, `scm`, `from`, `share_source`, `share_medium`, `vd_source` (bilibili), `ref_src`, `ref_url`. Keep everything else and keep the fragment. Drop a trailing `?` when no items remain.

`apply` returns nil when the output equals the input **only** for `cleanURL` and the JSON cases (so the UI can say 「没有可处理的内容」); for the others return the result even if unchanged.

Tests (`Tests/ClipShelfTests/PasteTransformTests.swift`): every case at least once, including: invalid JSON → nil, base64 decode of non-UTF-8 → nil, cleanURL on text containing two URLs with mixed params, Chinese text through capitalized/uppercase unchanged-but-non-nil, dedupe keeps order, CRLF input handled for line ops.

### Wiring

- `ClipboardStore`: add `func transformed(_ clip: Clip, with transform: PasteTransform) -> Clip?` that returns a **temporary** clip (new UUID, `.text(result, rtf: nil, html: nil)`, or `.link` when the result is a single web URL and the source was a link). It must not be inserted into history by this call. Only applies when `clip.payload.supportsPlainText`.
- Paste it with `onPaste(transformedClip, true)` exactly like `pasteJoined` does today.
- The copy that lands on the pasteboard will be captured into history by the normal poll — that is fine and expected.

### UI (ShelfView)

- Card context menu: after 「粘贴为纯文本」 add a submenu **「处理后粘贴」** listing the transforms grouped by section with `Divider()` between sections. Only for clips where `supportsPlainText`.
- Same submenu in the footer next to 「粘贴」 as a `Menu` with a `wand.and.stars` icon, only when a single text/link clip is selected.
- Keyboard: `⌥↩` opens a small transform picker over the selected card: a list in a popover/sheet, arrow keys move, ↩ applies and pastes, Esc closes, typing filters by Chinese title. Add the hint to the footer help text (`⌥↩ 处理后粘贴`) and README.
- Remember the last used transform (UserDefaults via `ShelfPreferences`) and show it first in the picker with a 「上次使用」 label.
- If `apply` returns nil: footer message 「没有可处理的内容」, nothing is pasted.

## B. 粘贴为… (format choice)

Text clips can carry RTF and HTML. Add a submenu **「粘贴为」** (card context menu and footer menu, text clips only):

- 「原格式」 — current behaviour (`plainText: false`).
- 「纯文本」 — current `plainText: true`.
- 「Markdown」 — convert to Markdown, paste as plain text.
- 「HTML 源码」 — paste the HTML markup as plain text. Disabled when the clip has neither HTML nor RTF.

Markdown conversion: new pure-ish file `Sources/ClipShelf/MarkdownExport.swift`. Build an `NSAttributedString` from HTML (preferred) or RTF, then walk attributes: bold → `**`, italic → `*`, bold+italic → `***`, `.link` → `[text](url)`, monospaced font → backticks (fenced ``` block when the run spans whole lines), paragraphs separated by blank line, `NSTextList` bullets → `- ` / `1. `, headings when font size ≥ 1.5× body → `#`/`##`. Keep it modest; correctness on common Notes/Safari/Word copies matters more than completeness. When there is no rich data, Markdown = the plain text. HTML source when only RTF exists: generate via `NSAttributedString.data(from:documentAttributes: [.documentType: .html])`.

Tests: bold/italic/link/list/monospace round trips from small HTML strings; plain-text fallback.

Note: `NSAttributedString(html:)` must run on the main thread — `ClipboardStore` is `@MainActor`, keep it there.

## Acceptance

- Right-click a text card → 「处理后粘贴 → JSON 格式化」 pastes pretty JSON into TextEdit.
- `⌥↩` picker works fully from the keyboard.
- Copy a bold+link paragraph from Safari → 「粘贴为 → Markdown」 gives `**…**` and `[…](…)`.
- `swift build` and `swift test` pass.
