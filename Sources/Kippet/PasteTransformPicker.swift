import AppKit
import SwiftUI

struct PasteTransformPicker: View {
    let lastUsed: PasteTransform?
    let onPick: (PasteTransform) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var isFiltering = false
    @State private var highlighted: PasteTransform?

    private var results: [PasteTransform] {
        let matches = PasteTransform.allCases.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        guard let lastUsed, matches.contains(lastUsed) else { return matches }
        return [lastUsed] + matches.filter { $0 != lastUsed }
    }

    private var selection: PasteTransform? {
        let matches = results
        if let highlighted, matches.contains(highlighted) { return highlighted }
        return matches.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ShelfSearchField(
                    text: $query, isEditing: $isFiltering, placeholder: L("筛选处理方式"),
                    focusOnInstall: true, onCommand: handleCommand, onInstall: { _ in }
                )
                .frame(height: 22)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: ShelfTheme.chipRadius))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { transform in
                            Button { onPick(transform) } label: {
                                HStack {
                                    Text(transform.title)
                                    Spacer(minLength: 4)
                                    if transform == lastUsed {
                                        Text("上次使用").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 27)
                                .background {
                                    if transform == selection {
                                        RoundedRectangle(cornerRadius: ShelfTheme.chipRadius)
                                            .fill(ShelfTheme.accent.opacity(0.18))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(transform == selection ? .isSelected : [])
                            .id(transform)
                        }
                    }
                }
                .onChange(of: selection) { _, transform in
                    if let transform { proxy.scrollTo(transform) }
                }
            }
            .overlay(alignment: .topLeading) {
                if results.isEmpty {
                    Text("没有匹配的处理方式")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .frame(height: 166)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ShelfTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ShelfTheme.cardRadius)
                .strokeBorder(ShelfTheme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(radius: 10)
        .accessibilityLabel("处理后粘贴")
        .onChange(of: query) { _, _ in highlighted = nil }
        .onExitCommand(perform: onCancel)
    }

    private func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.insertNewline(_:)):
            if let selection { onPick(selection) }
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel()
        default:
            return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        let matches = results
        guard let selection, let index = matches.firstIndex(of: selection) else { return }
        highlighted = matches[min(max(index + step, 0), matches.count - 1)]
    }
}
