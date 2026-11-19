# Phase 4 — 给 AI 工具（MCP）和快捷指令用

Read `AGENTS.md` first. Phases 1–3 are in the tree.

Two entry points, both **off by default** and both read-only except where stated.

## A. Local MCP server (stdio)

Run mode inside the same executable: `ClipShelf.app/Contents/MacOS/ClipShelf --mcp`. When launched with `--mcp`, do **not** start the menu-bar app (`NSApplication`); run a stdio JSON-RPC 2.0 loop instead and exit on EOF. Branch at the very top of `ClipShelfApp.main()`.

- Protocol: MCP over stdio, newline-delimited JSON. Implement `initialize` (protocolVersion `2025-06-18`, serverInfo `{name: "clipshelf", version: CFBundleShortVersionString}`, capabilities `{tools: {}}`), `notifications/initialized`, `tools/list`, `tools/call`, `ping`. Unknown methods → JSON-RPC error -32601. Write a small hand-rolled codec with `JSONSerialization`/`Codable`; no dependencies. Logs go to stderr only.
- Data access: open `History.sqlite3` **read-only** through `ClipArchive` (add a read-only open path if needed; WAL-safe; never write). Load on each call so it reflects the running app.
- Gate: if the user hasn't enabled it in preferences (UserDefaults suite of the app bundle id `com.clipshelf.macos`, key e.g. `mcpEnabled`), every `tools/call` returns an MCP tool error 「拾贴未开启 AI 访问，请在 设置 → 自动化 中打开」. Clips with `expiresAt` (OTP etc.) and clips from rule-skipped/excluded sources are never returned. Images return metadata only (size, OCR text), never bytes.
- Tools:
  - `search_clips {query: string, kind?: "text"|"link"|"image"|"files", limit?: int ≤ 50}` → id, date (ISO8601), kind, source app, title, preview (≤ 500 chars), pinboards.
  - `list_recent {limit?: int ≤ 50}`.
  - `get_clip {id}` → full text (≤ 100 KB, truncated flag), link, file paths, OCR text, note.
  - `list_pinboards {}` → id, name, count.
  - `list_pinboard_clips {pinboard_id, limit?}`.
  - `add_snippet {title?, content, pinboard_id?}` — the only write. Must not write the database from the MCP process; instead post a `DistributedNotificationCenter` notification (`com.clipshelf.macos.addSnippet`, userInfo with title/content/pinboard) that the running app handles via `store.createSnippet`, and return 「已发送给拾贴」. If the app isn't running, return an error saying so. Separate preference toggle 「允许 AI 新建片段」, off by default.
- Factor the request handling into a pure `MCPServer` type that takes an input line and returns output lines, so tests can drive it without stdio. Tests: initialize handshake, tools/list schema shape, search over a temp archive, gate off → error, OTP clip hidden.

## B. URL scheme for 快捷指令 / Raycast / Alfred

Register `clipshelf://` in `Info.plist` (`CFBundleURLTypes`). Handle in the app delegate (`application(_:open:)`):

- `clipshelf://open` — show the shelf.
- `clipshelf://search?q=…` — show the shelf with the search filled.
- `clipshelf://stack` — open the paste stack.
- `clipshelf://snippet/new?text=…&title=…&pinboard=…` — open the new-snippet sheet prefilled (never saves silently).
- `clipshelf://copy?index=1` — put the Nth item of history (1-based) on the pasteboard, no paste. Off unless 「允许链接复制历史」 is on.
- Unknown paths are ignored. Parse with `URLComponents` in a pure `ShelfURLCommand` enum with tests.

AppIntents are out of scope: SwiftPM builds don't produce the metadata Shortcuts needs. Shortcuts can call the URL scheme with 「打开 URL」.

## Preferences UI

New tab 「自动化」:
- Toggle 「允许 AI 工具读取历史（MCP）」, with one-line privacy note: 「仅本机，验证码和被排除来源不会提供」.
- Toggle 「允许 AI 新建片段」 (disabled unless the first is on).
- A read-only, copyable config snippet for Claude Desktop / Claude Code / Cursor:
  ```json
  { "mcpServers": { "clipshelf": { "command": "/Applications/ClipShelf.app/Contents/MacOS/ClipShelf", "args": ["--mcp"] } } }
  ```
  using the app's actual `Bundle.main.executablePath`, plus a 「复制」 button and a 「复制 Claude Code 命令」 button producing `claude mcp add clipshelf -- "<path>" --mcp`.
- Toggle 「允许链接复制历史」 and a list of the URL commands with copy buttons.

## Acceptance

- `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | dist/ClipShelf.app/Contents/MacOS/ClipShelf --mcp` prints two valid responses and exits, without a menu-bar icon appearing.
- With the toggle off, `tools/call search_clips` returns the gate error.
- `open 'clipshelf://search?q=hello'` opens the shelf with 「hello」 searched.
- `swift build` and `swift test` pass.
