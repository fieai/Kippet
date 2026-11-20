import SwiftUI

extension ShelfView {
    func fullPreview(_ clip: Clip) -> some View {
        let detection = store.detectionCache.result(for: clip)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(clip.title ?? detection?.label ?? clip.storedPayload.kind.label,
                      systemImage: detection?.symbol ?? clip.storedPayload.kind.symbol)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if clip.storedPayload.kind == .text && textEditorID != clip.id {
                    Button("编辑正文…") { startEditingText(clip) }
                }
                if clip.hasPreviewImage {
                    Button(extractionID == clip.id ? L("查看图片") : L("提取图片中的文字")) {
                        if extractionID == clip.id { extractionID = nil } else { showExtraction(clip) }
                    }
                }
            }
            if textEditorID == clip.id {
                TextEditor(text: $textDraft)
                    .focused($draftFocused)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("卡片正文")
                HStack {
                    if let editError { Text(editError).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    Button("取消", action: stopEditingText)
                    Button("保存") { saveText(clip, paste: false) }
                    Button("保存并粘贴") { saveText(clip, paste: true) }
                        .buttonStyle(.borderedProminent)
                }
            } else if case let .link(value) = clip.storedPayload {
                ShelfLinkPreview(url: value)
            } else if clip.hasPendingSyncImage || clip.hasPreviewImage {
                if extractionID == clip.id {
                    OCRTextPreview(id: clip.id, store: store, onCopy: copyText)
                } else {
                    ShelfThumbnail(clip: clip, maxPixelSize: 1400)
                }
            } else if let detection {
                DetectedContentView(detection: detection, source: clip.storedPayload.previewText, copy: copyText)
            } else {
                ScrollView {
                    Text(clip.storedPayload.previewText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func showExtraction(_ clip: Clip) {
        onReturnToCards()
        browser.selectCard(clip.id)
        if !browser.isPreviewing { browser.togglePreview() }
        extractionID = clip.id
    }

    func startEditingText(_ clip: Clip) {
        guard case let .text(text, _, _) = clip.storedPayload else { return }
        onReturnToCards()
        browser.selectedID = clip.id
        if !browser.isPreviewing { browser.togglePreview() }
        textEditorID = clip.id
        textDraft = text
        editError = nil
        status.isEditingClip = true
        draftFocused = true
    }

    func stopEditingText() {
        guard textEditorID != nil else { return }
        draftFocused = false
        textEditorID = nil
        editError = nil
        status.isEditingClip = false
    }

    private func saveText(_ clip: Clip, paste: Bool) {
        guard let updated = store.editText(clip.id, text: textDraft) else {
            editError = L("无法保存，请检查正文是否为空或超出容量。")
            return
        }
        stopEditingText()
        onReturnToCards()
        if paste {
            onPaste(updated, false)
        } else {
            status.pasteMessage = nil
            message = L("已保存正文")
        }
    }

    func titleEditorSheet(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("卡片备注").font(.headline)
            TextField("输入便于搜索的备注", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
            if let editError { Text(editError).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { titleEditor = nil }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if store.rename(clip.id, title: titleDraft) {
                        titleEditor = nil
                    } else {
                        editError = L("无法保存备注，请控制在 120 个字符以内。")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}

private struct OCRTextPreview: View {
    let id: Clip.ID
    let store: ClipboardStore
    let onCopy: (String) -> Void
    @State private var text: String?
    @State private var completed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("复制识别文字") { onCopy(text) }
            } else if completed {
                Text(text == nil ? L("暂时无法识别这张图片") : L("未在图片中识别到文字"))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("正在识别图片文字").controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: id) {
            let result = await store.recognizeText(id)
            guard !Task.isCancelled else { return }
            text = result
            completed = true
        }
    }
}
