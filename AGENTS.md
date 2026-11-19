# Kippet（拾贴）— rules for coding agents

macOS 14+ clipboard manager, Swift 6 / SwiftPM, SwiftUI + AppKit. Mac only.

## Build and verify (run both before you finish)

```sh
swift build
swift test
```

Both must succeed with no new warnings in files you touched. Add tests in `Tests/KippetTests` (Swift Testing, `@Test`) for every pure-logic piece you add.

## Hard rules

- Do NOT `git commit`, `git stash`, `git reset`, `git checkout --`, or switch branches. Leave changes in the working tree for review.
- Do not run `./Scripts/build-app.sh` (it signs with the user's keychain; the reviewer runs it).
- Do not touch `dist/`, `.kippet-signing-identity`, `.clipshelf-signing-identity`, `Scripts/configure-signing.sh`, or signing settings.
- Do not delete or rewrite existing behaviour you were not asked to change. Existing tests must keep passing unchanged.
- Never add network calls except where the spec says so. History never leaves the Mac.
- No third-party dependencies.
- Keep the stored history format backwards compatible: new `Clip` fields must be optional with defaults so old `History.sqlite3` rows still decode.

## Style

- UI copy is Simplified Chinese, short and plain, matching existing strings (e.g. 「已复制」「粘贴为纯文本」). Use 「」 quotes.
- Visual tokens and animations live in `Sources/Kippet/ShelfTheme.swift` (`ShelfTheme`, `ShelfMotion`). Reuse them; don't hardcode new colors or springs.
- Pure logic goes in its own file with no AppKit/SwiftUI dependency where possible, so it is testable.
- Match the surrounding code: small types, `@MainActor` on UI/state types, `Sendable` value types.
- Update `README.md` (Chinese) with a short bullet for each user-visible feature you add.

## When done

End with a short summary: files changed, what you tested, anything you could not finish or verify.
