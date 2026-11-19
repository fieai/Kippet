# Phase 2 — 识别内容类型（颜色、代码、验证码、联系方式、二维码）

Read `AGENTS.md` first. Phase 1 is already in the tree; don't break it.

## Detector

New file `Sources/ClipShelf/ContentDetector.swift`, Foundation only, pure and fast (called while rendering cards, so cache per clip id — see below):

```swift
enum DetectedContent: Equatable, Sendable {
    case color(red: Double, green: Double, blue: Double, alpha: Double, original: String)
    case code(language: CodeLanguage?)      // CodeLanguage: swift, js/ts, python, json, html, css, shell, sql, go, rust, other
    case oneTimeCode(String)                // the digits/letters only
    case email(String)
    case phone(String)
}
enum ContentDetector { static func detect(_ text: String) -> DetectedContent? }
```

Rules (only on `.text` payloads; trim first):

- **color**: whole string is one of `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb(…)`, `rgba(…)`, `hsl(…)`, `hsla(…)`, or SwiftUI/UIKit-ish `Color(red: …, green: …, blue: …)`. Case-insensitive, allow spaces.
- **oneTimeCode**: text ≤ 200 chars containing a keyword (验证码, 校验码, 动态码, 确认码, verification code, security code, one-time, OTP, code is, 代码) and exactly one standalone token of 4–8 digits (or 6–8 alphanumerics with at least one digit when the keyword is English). Also the bare token alone (`^\d{4,8}$`) when the clip source bundle id is `com.apple.MobileSMS`, `com.apple.Passwords`, or `com.tencent.xinWeChat` — pass the bundle id as an optional second argument.
- **email / phone**: whole trimmed string is a single email / a single phone number (use `NSDataDetector` for phone; accept CN 11-digit mobiles and `+` international).
- **code**: ≥ 2 lines and a score from cheap signals (braces/semicolon line endings, leading indentation on ≥ 40% of lines, keywords like `func `, `let `, `const `, `def `, `import `, `return `, `=>`, `</`, `SELECT `, `#!/`). Threshold tuned so normal Chinese/English prose never triggers. Guess the language from the strongest keywords; JSON if it parses with `JSONSerialization`.
- Order: color → oneTimeCode → email → phone → code. Return nil otherwise.

Tests (`ContentDetectorTests.swift`): ≥ 25 cases including negatives — Chinese paragraphs, a sentence with a year (2026) must not be OTP, a phone inside a sentence is not `.phone`, Markdown prose is not code, minified JSON is code(json).

Cache: `@MainActor final class DetectionCache` keyed by `Clip.ID` + payload hash, `NSCache`-style limit ~500. Text edits (`editText`) must invalidate.

## Card visuals (ShelfView `ClipCard`)

Keep the card frame/size and the meta row; replace only the preview area per type:

- **color**: big rounded swatch filling the preview (checkerboard behind when alpha < 1), the original string in monospaced text below, plus small secondary line with the other notations (HEX ↔ RGB). Meta chip label 「颜色」 with `paintpalette` symbol.
- **code**: monospaced 11.5pt, light syntax tint with a tiny tokenizer (keywords, strings, numbers, comments) — no dependency; max ~40 lines tokenized. Meta chip 「代码 · Swift」 etc. with `chevron.left.forwardslash.chevron.right`.
- **oneTimeCode**: the code in large rounded monospaced digits (28pt, letter-spaced) centered, the original text in 2 lines secondary below. Meta chip 「验证码」 `number.square`.
- **email / phone**: big value + action icons row (`envelope` → `mailto:`, `phone` → `tel:` via `NSWorkspace.open`, with confirmation-free open since it only opens the app).

Full preview (space) mirrors this: color shows swatch + all notations each with a copy button; code shows a scrollable highlighted view.

Context menu additions:
- color: 「复制为 HEX」「复制为 RGB」「复制为 HSL」「复制为 SwiftUI Color」.
- oneTimeCode: 「只复制验证码」 (copies just the code).
- email/phone: 「发邮件」/「拨打」.

Filtering: extend the type picker in the toolbar with 「颜色」「代码」「验证码」 as extra filter options (keep the existing four kinds). Implement in `ShelfBrowser`/`HistoryFilter` without changing `ClipKind` storage — the detector result is derived, never persisted.

## QR codes in images

In `ClipOCR.swift` (or a sibling `ClipBarcode.swift`), add Vision `VNDetectBarcodesRequest` for QR/Aztec/DataMatrix/PDF417 run in the same background pass as OCR, results kept the same way `recognizedText` is (add optional `Clip.barcodePayloads: [String]?`, backwards compatible). On image cards with a barcode, show a small `qrcode` badge on the thumbnail corner; context menu 「复制二维码内容」 (and 「打开链接」 when it is a web URL). Include barcode text in search.

## Acceptance

- Copying `#14B8A6` shows a teal swatch card; filter 「颜色」 shows it.
- An SMS-style 「您的验证码是 482913，5 分钟内有效」 card shows 482913 large; 「只复制验证码」 works.
- A Swift snippet shows highlighted code with 「代码 · Swift」.
- A screenshot with a QR code gets the badge and its content is searchable.
- Prose never shows as code in a quick manual check of 10 normal clips.
- `swift build` and `swift test` pass.
