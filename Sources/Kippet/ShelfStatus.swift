import Foundation
import Observation

@MainActor
@Observable
final class ShelfStatus {
    var shortcutAvailable = false
    var pasteMessage: String?
    var directPasteAccess = DirectPasteAccess.needsAccessibility
    var showPasteAccessPrompt = false
    var panel = ShelfPanelState()
    var isPinned: Bool { panel.isPinned }
    var commandHeld = false
    var isDragging = false
    var isEditingClip = false
    var shortcutLabel = "⌥⇧V"
    var stackShortcutAvailable = false
    var stackShortcutLabel = "⌃⌥V"
    var showsStack = false
    var isPastingStack = false
    var snippetDraft: SnippetDraft?
    var showsSnippetEditor: Bool { snippetDraft != nil }
    var ruleDraft: ClipRule?
    var shelfIsOpen: Bool { panel.isOpen }
    var searchFocused = false
    var transformClip: Clip?
}

struct SnippetDraft: Identifiable {
    let id = UUID()
    var title = ""
    var content = ""
    var groupID: ClipGroup.ID?
}
