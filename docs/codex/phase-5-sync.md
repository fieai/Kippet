# Phase 5 — 多台 Mac 同步收藏与钉板（通过云盘文件夹）

Read `AGENTS.md` first. Phases 1–4 are in the tree.

CloudKit needs provisioning that this SwiftPM + Developer ID build doesn't have, so sync goes through a **user-chosen folder** (iCloud Drive, Dropbox, Syncthing, NAS…). Only *saved* things sync: starred clips, pinboards, clips in pinboards, snippets, card notes, pinboard order and colors. Plain history never syncs. Images inside saved clips do sync (they're already capped by the 32 MiB favorites budget).

## Format

Folder layout, one subfolder per device so two Macs never write the same file:

```
<chosen folder>/ClipShelf Sync/
  devices/<deviceID>/state.json        # this Mac's full saved set, rewritten atomically
  devices/<deviceID>/blobs/<sha256>    # image / large payload bytes, content-addressed, immutable
```

`state.json` (Codable, versioned `"format": 1`):
- `device`: id (UUID stored in UserDefaults), name (`Host.current().localizedName`), `updatedAt`.
- `clips`: for each saved clip: id, payload (text/link inline; image/rtf/html as blob hash refs; file URLs kept as paths with a flag that they may not exist on other Macs), date, title, isFavorite, groupIDs, `modifiedAt`.
- `groups`: id, name, color, cardOrder, `modifiedAt`.
- `tombstones`: `{id, kind: clip|group, deletedAt}` kept 30 days.

Add `modifiedAt: Date?` to `Clip` and `ClipGroup` (optional, backwards compatible), bumped by every mutation of saved state in `ClipboardStore` (favorite, group membership, rename, editText, group rename/color/reorder/card order, snippet create, delete).

## Merge

Pure `SyncMerge` type (unit-tested heavily):

- Inputs: local saved set + every other device's `state.json`.
- Per id, last-writer-wins on `modifiedAt`; a tombstone newer than the record deletes it; a record newer than the tombstone resurrects it.
- Group name collisions across different ids → keep both, suffix the newer one 「（2）」.
- `cardOrder` follows the winning group record; ids that don't exist locally are dropped from order but kept in the file.
- Unsaving a clip (unstar + no groups) on one Mac = tombstone for the saved record; the other Mac keeps the clip in its local history only if it was already there.
- Never deletes anything from plain (unsaved) local history.

## Engine

`SyncEngine` (`@MainActor`):
- Writes own `state.json` (atomic write via temp file + rename) debounced 2 s after saved-state changes, and on quit.
- Reads others on launch, on shelf open, and via `NSFilePresenter`/`DispatchSource` folder watch (fallback: poll every 60 s). Ignore files whose JSON fails to decode (partial cloud downloads); retry later.
- Blobs: write before state that references them; missing blob on read → keep the record but show the card as 「图片尚未同步」 and retry.
- iCloud Drive placeholders (`.icloud` files): call `FileManager.startDownloadingUbiquitousItem` and retry.
- Security-scoped bookmark for the chosen folder (the app isn't sandboxed today, but store a bookmark anyway so the path survives renames).
- Status published for the UI: idle / syncing / last synced date / error string.

## UI

- Preferences tab 「同步」: 「选择同步文件夹…」 (NSOpenPanel, directories only, suggests `~/Library/Mobile Documents/com~apple~CloudDocs`), current folder, 「立即同步」, last sync time, list of other devices seen with their last update, 「停止同步」 (keeps local data, leaves files), and a short note 「只同步收藏、钉板和片段，普通历史不会离开这台 Mac」.
- Shelf toolbar: tiny sync status glyph next to the pin (`arrow.triangle.2.circlepath`, rotating while syncing, orange `exclamationmark.icloud` on error with tooltip). Hidden when sync is off.

## Tests

`SyncMergeTests.swift`: LWW both directions, tombstone vs. edit ordering, resurrect, group name collision, card order with unknown ids, unsave flow, blob ref round trip, decoding of an older/partial state file is rejected cleanly. `SyncEngineTests` with two temp folders simulating two devices exchanging a star, a pinboard rename and a deletion.

## Acceptance

- Two user accounts or two copies of the app pointing at the same folder (use different device ids) converge after starring, renaming a pinboard, reordering cards, and deleting a pinboard on either side.
- Plain history never appears in `state.json` (assert in a test).
- `swift build` and `swift test` pass.
