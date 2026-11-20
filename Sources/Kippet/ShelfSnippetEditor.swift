import SwiftUI

struct ShelfSnippetEditor: View {
    let groups: [ClipGroup]
    let onSave: (String, String, ClipGroup.ID?) -> Bool
    let onCancel: () -> Void
    @State private var groupID: ClipGroup.ID?
    @State private var title: String
    @State private var content: String
    @State private var error: String?
    @FocusState private var editingContent: Bool

    init(
        groups: [ClipGroup], draft: SnippetDraft,
        onSave: @escaping (String, String, ClipGroup.ID?) -> Bool, onCancel: @escaping () -> Void
    ) {
        self.groups = groups
        self.onSave = onSave
        self.onCancel = onCancel
        _groupID = State(initialValue: draft.groupID)
        _title = State(initialValue: draft.title)
        _content = State(initialValue: draft.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建片段").font(.headline)
            TextField("标题（可选）", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $content)
                .focused($editingContent)
                .font(.body)
                .frame(height: 116)
                .padding(5)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)) }
                .accessibilityLabel("片段正文或链接")
            Picker("保存到", selection: $groupID) {
                Text("全部收藏").tag(nil as ClipGroup.ID?)
                ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") {
                    if !onSave(title, content, groupID) {
                        error = L("无法保存，请检查标题长度、正文大小或收藏容量。")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!content.contains { !$0.isWhitespace })
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { editingContent = true }
    }
}

extension ShelfView {
    func saveSnippet(_ title: String, _ content: String, _ groupID: ClipGroup.ID?) -> Bool {
        guard let clip = store.createSnippet(title: title, content: content, in: groupID) else { return false }
        browser.search = ""
        browser.contentType = nil
        browser.sourceName = nil
        browser.sourceBundleIdentifier = nil
        selectBoard(favorites: true, groupID: groupID)
        browser.isPreviewing = false
        browser.selectedID = clip.id
        status.snippetDraft = nil
        status.pasteMessage = nil
        message = L("已保存片段")
        return true
    }
}
