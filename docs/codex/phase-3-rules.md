# Phase 3 — 自动规则（归档、过期、跳过、加星）

Read `AGENTS.md` first. Phases 1–2 are in the tree. Reuse `ContentDetector` from phase 2.

## Model

New file `Sources/ClipShelf/ClipRule.swift` (pure, Codable, Sendable):

```swift
struct ClipRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var match: Match           // all non-nil conditions must hold
    var action: Action
    struct Match: Codable, Equatable, Sendable {
        var sourceBundleIdentifiers: [String]?   // any of
        var kinds: [ClipKind]?                   // any of
        var detected: [DetectedKind]?            // color, code, oneTimeCode, email, phone
        var textContains: String?                // case-insensitive
        var regex: String?                       // NSRegularExpression; invalid → rule never matches, UI shows error
    }
    enum Action: Codable, Equatable, Sendable {
        case addToGroup(UUID)
        case favorite
        case expire(after: TimeInterval)         // 60 s … 7 days
        case skip                                // don't record at all
    }
}
enum RuleEngine { static func actions(for clip: Clip, detected: DetectedContent?, rules: [ClipRule]) -> [ClipRule.Action] }
```

Multiple rules may match; `skip` wins over everything. Rules are evaluated in list order.

## Built-in presets

Seeded on first launch of this version (not re-added if the user deletes them), all **enabled** except where noted:

1. 「验证码 2 分钟后删除」 — detected oneTimeCode → expire(120).
2. 「密码管理器内容不记录」 — source in 1Password (`com.1password.1password`, `com.agilebits.onepassword7`), Bitwarden (`com.bitwarden.desktop`), Apple Passwords (`com.apple.Passwords`) → skip. (Existing concealed-type skipping stays; this is belt and braces.)
3. 「颜色归入『颜色』钉板」 — detected color → addToGroup — **disabled** by default; enabling it creates the pinboard if missing.

## Engine wiring

- `ClipboardStore.poll`: after building the clip and before insert, run the engine. `skip` → return false without saving. `favorite` / `addToGroup` → apply (respect favorites capacity; if it fails, still keep the clip in history). `expire` → store `Clip.expiresAt: Date?` (new optional field, backwards compatible).
- Expiry sweep: a timer on the store (every 30 s while running, plus on launch and on each `open()` of the shelf) removes clips whose `expiresAt` has passed **unless** the user has since starred/pinned them (saving a clip clears `expiresAt`). Removal goes through the same path as normal deletion so the archive is updated; no undo toast for expiry.
- Cards with `expiresAt` show a small countdown in the meta row (`timer` symbol + 「1:42」, update each second only for visible cards via `TimelineView(.periodic)`), and the meta chip turns orange in the last 15 s.
- Rule application must be unit-testable without a real pasteboard: put the decision logic in `RuleEngine`, keep the store glue thin.

## Preferences UI

New tab 「规则」 in `ShelfPreferencesView`:

- List of rules with enable toggle, name, a one-line summary (「来自 微信 · 验证码 → 2 分钟后删除」), drag to reorder, delete.
- 「新建规则…」 sheet: name; conditions (source app picker from `store.sources` + 「选择应用…」 file picker for /Applications; kind checkboxes; detected-type checkboxes; contains text; regex with live validation); action picker (pinboard picker from groups, favorite, expire with duration stepper 1 min / 5 min / 15 min / 1 h / 1 d / 7 d, skip).
- Store rules in `ShelfPreferences` (UserDefaults JSON, same pattern as `excludedApps`).
- A rule that points at a deleted pinboard shows a warning and is skipped at runtime.

## Card context menu

「为此来源新建规则…」 opens the new-rule sheet prefilled with the card's source and kind.

## Tests

`RuleEngineTests.swift`: each condition alone, combined conditions, skip precedence, invalid regex never matches, disabled rule ignored, deleted-group rule ignored, preset 1 matches the phase-2 OTP sample. Store-level test (using the existing test pasteboard helpers in `ClipboardStoreTests` if present) that an expired clip is swept and a starred one is not.

## Acceptance

- Copy 「验证码 482913」 → card shows countdown → gone after 2 min; starring it before then keeps it.
- Copy from Bitwarden → nothing recorded.
- New rule 「来自 Figma → 设计 钉板」 files new Figma copies automatically.
- `swift build` and `swift test` pass.
