import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfRulesView: View {
    let store: ClipboardStore
    @State private var draft: ClipRule?

    private var preferences: ShelfPreferences { store.shelfPreferences }

    var body: some View {
        let sources = store.sources
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(preferences.rules) { rule in
                    ruleRow(rule, sources: sources)
                }
                .onMove { preferences.rules.move(fromOffsets: $0, toOffset: $1) }
            }
            Button("新建规则…") {
                draft = ClipRule(id: UUID(), name: "", isEnabled: true, match: .init(), action: .favorite)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
        .sheet(item: $draft) { rule in ClipRuleEditor(rule: rule, store: store) }
    }

    private func ruleRow(_ rule: ClipRule, sources: [ClipSource]) -> some View {
        let name = rule.displayName
        let group = store.groups.first { $0.id == rule.action.groupID }
        let isUnassignedColorPreset = rule.id == ClipRule.colorPresetID
            && rule.action.groupID == ClipRule.colorPresetID && !rule.isEnabled
        let missingGroup = rule.action.groupID != nil && group == nil && !isUnassignedColorPreset
        return HStack(spacing: 10) {
            Toggle(L("启用%@", name), isOn: Binding(
                get: { rule.isEnabled },
                set: { store.setRuleEnabled(rule.id, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                Text(summary(rule, group: group, isUnassignedColorPreset: isUnassignedColorPreset, sources: sources))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if missingGroup {
                    Label("目标钉板已删除", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.warning)
                }
                if rule.match.hasInvalidRegex {
                    Text("正则表达式无效").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                preferences.rules.removeAll { $0.id == rule.id }
            } label: {
                Label(L("删除%@", name), systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func summary(
        _ rule: ClipRule, group: ClipGroup?, isUnassignedColorPreset: Bool, sources: [ClipSource]
    ) -> String {
        var conditions: [String] = []
        if let ids = rule.match.sourceBundleIdentifiers {
            let names = ids.map { ruleSourceName($0, sources: sources) }
            conditions.append(L("来自 %@", names.joined(separator: L("、"))))
        }
        if let kinds = rule.match.kinds { conditions.append(kinds.map(\.label).joined(separator: L("、"))) }
        if let types = rule.match.detected { conditions.append(types.map(\.label).joined(separator: L("、"))) }
        if let contains = rule.match.textContains { conditions.append(L("包含「%@」", contains)) }
        if let regex = rule.match.regex { conditions.append(L("正则「%@」", regex)) }
        let action: String
        switch rule.action {
        case .addToGroup:
            let name = group?.name ?? (isUnassignedColorPreset ? L("颜色") : L("已删除的钉板"))
            action = L("归入「%@」", name)
        case .favorite: action = L("加星标")
        case let .expire(after: seconds):
            let label = seconds == 120 ? L("2 分钟") : expiryChoices.first { $0.seconds == seconds }?.label
            action = L("%@后删除", label ?? L("%@ 秒", seconds.formatted()))
        case .skip: action = L("跳过记录")
        }
        return (conditions.isEmpty ? L("全部内容") : conditions.joined(separator: " · ")) + " → " + action
    }
}

struct ClipRuleEditor: View {
    let store: ClipboardStore
    private let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var match: ClipRule.Match
    @State private var action = ActionChoice.favorite
    @State private var groupID: ClipGroup.ID?
    @State private var expiryIndex = 0
    @State private var pickingApps = false
    @State private var pickedApps: [String: String] = [:]
    @State private var appSelectionError: String?

    private enum ActionChoice: CaseIterable {
        case pinboard, favorite, expire, skip

        var label: String {
            switch self {
            case .pinboard: L("归入钉板")
            case .favorite: L("加星标")
            case .expire: L("到期删除")
            case .skip: L("跳过记录")
            }
        }
    }

    init(rule: ClipRule, store: ClipboardStore) {
        self.store = store
        id = rule.id
        _name = State(initialValue: rule.name)
        _match = State(initialValue: rule.match)
    }

    var body: some View {
        let invalidRegex = match.hasInvalidRegex
        VStack(alignment: .leading, spacing: 0) {
            Text("新建规则").font(.headline).padding([.top, .horizontal], 16)
            Form {
                TextField("名称", text: $name)
                Section("条件") {
                    sourcePicker
                    LabeledContent("内容类型") {
                        HStack {
                            ForEach(ClipKind.allCases) { kind in
                                Toggle(kind.label, isOn: selection(kind, in: \.kinds))
                            }
                        }
                    }
                    LabeledContent("识别类型") {
                        HStack {
                            ForEach(DetectedKind.allCases, id: \.self) { type in
                                Toggle(type.label, isOn: selection(type, in: \.detected))
                            }
                        }
                    }
                    TextField("包含文字", text: textCondition(\.textContains))
                    TextField("正则表达式", text: textCondition(\.regex))
                    if invalidRegex {
                        Text("正则表达式无效").foregroundStyle(.red)
                    }
                }
                .toggleStyle(.checkbox)
                Section("操作") {
                    Picker("操作", selection: $action) {
                        ForEach(ActionChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    switch action {
                    case .pinboard:
                        if store.groups.isEmpty {
                            Text("请先新建钉板").foregroundStyle(.secondary)
                        } else {
                            Picker("钉板", selection: $groupID) {
                                Text("选择钉板").tag(nil as ClipGroup.ID?)
                                ForEach(store.groups) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    case .expire:
                        Stepper(L("删除时限 %@", expiryChoices[expiryIndex].label), value: $expiryIndex,
                                in: 0...(expiryChoices.count - 1))
                    case .favorite, .skip:
                        EmptyView()
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || invalidRegex || ruleAction == nil)
            }
            .padding(16)
        }
        .frame(width: 535, height: 490)
        .fileImporter(
            isPresented: $pickingApps, allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: true, onCompletion: addApps
        )
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    private var sourcePicker: some View {
        let sources = store.sources
        let chosen = match.sourceBundleIdentifiers ?? []
        var apps = pickedApps
        for source in sources {
            if let identifier = source.bundleIdentifier { apps[identifier] = source.name }
        }
        for id in chosen where apps[id] == nil { apps[id] = ruleSourceName(id, sources: sources) }
        let appIDs = apps.keys.sorted {
            let order = (apps[$0] ?? $0).localizedStandardCompare(apps[$1] ?? $1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return LabeledContent("来源应用") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Menu("选择来源") {
                        if appIDs.isEmpty { Text("暂无来源应用") }
                        ForEach(appIDs, id: \.self) { id in
                            Toggle(apps[id] ?? id, isOn: selection(id, in: \.sourceBundleIdentifiers))
                        }
                    }
                    Button("选择应用…") { pickingApps = true }
                }
                if !chosen.isEmpty {
                    Text(chosen.map { apps[$0] ?? $0 }.joined(separator: L("、")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let appSelectionError { Text(appSelectionError).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var ruleAction: ClipRule.Action? {
        switch action {
        case .pinboard:
            store.groups.first { $0.id == groupID }.map { .addToGroup($0.id) }
        case .favorite: .favorite
        case .expire: .expire(after: expiryChoices[expiryIndex].seconds)
        case .skip: .skip
        }
    }

    private func selection<Value: Equatable>(
        _ value: Value, in field: WritableKeyPath<ClipRule.Match, [Value]?>
    ) -> Binding<Bool> {
        Binding {
            match[keyPath: field]?.contains(value) == true
        } set: { selected in
            var values = (match[keyPath: field] ?? []).filter { $0 != value }
            if selected { values.append(value) }
            match[keyPath: field] = values.isEmpty ? nil : values
        }
    }

    private func textCondition(_ field: WritableKeyPath<ClipRule.Match, String?>) -> Binding<String> {
        Binding {
            match[keyPath: field] ?? ""
        } set: { value in
            match[keyPath: field] = value.isEmpty ? nil : value
        }
    }

    private func addApps(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            var skipped = 0
            for url in urls {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
                    skipped += 1
                    continue
                }
                pickedApps[id] = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                var chosen = match.sourceBundleIdentifiers ?? []
                if !chosen.contains(id) {
                    chosen.append(id)
                    match.sourceBundleIdentifiers = chosen
                }
            }
            appSelectionError = skipped == 0 ? nil : L("有 %lld 个应用无法读取标识。", skipped)
        case .failure(let error):
            appSelectionError = L("无法选择应用。%@", error.localizedDescription)
        }
    }

    private func save() {
        guard let ruleAction, !trimmedName.isEmpty, !match.hasInvalidRegex else { return }
        store.shelfPreferences.rules.append(
            ClipRule(id: id, name: trimmedName, isEnabled: true, match: match, action: ruleAction)
        )
        dismiss()
    }
}

private let expiryChoices: [(seconds: TimeInterval, label: String)] = [
    (60, L("1 分钟")), (300, L("5 分钟")), (900, L("15 分钟")),
    (3_600, L("1 小时")), (86_400, L("1 天")), (604_800, L("7 天")),
]

@MainActor
private func ruleSourceName(_ id: String, sources: [ClipSource]) -> String {
    if let name = sources.first(where: { $0.bundleIdentifier == id })?.name { return name }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
}
