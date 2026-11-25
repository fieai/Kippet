import AppKit
import SwiftUI

struct ShelfSyncSettings: View {
    let sync: SyncEngine

    var body: some View {
        Form {
            Section {
                Button("选择同步文件夹…", action: chooseFolder)
                if let folder = sync.folder {
                    LabeledContent("当前文件夹") {
                        Text(folder.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.path)
                    }
                }
                if sync.isEnabled {
                    LabeledContent("上次同步") {
                        if let date = sync.lastSyncedAt {
                            Text(date, format: .dateTime.month().day().hour().minute().second())
                        } else {
                            Text("尚未同步")
                        }
                    }
                    if case let .error(message) = sync.status {
                        Text(message).foregroundStyle(ShelfTheme.warning)
                    }
                    HStack {
                        Button("立即同步") { Task { await sync.syncNow() } }
                            .disabled(sync.status == .syncing)
                        Button("停止同步", action: sync.stop)
                        // Kept on the button row so starting a sync never pushes the rows below.
                        ProgressView().controlSize(.small)
                            .opacity(sync.status == .syncing ? 1 : 0)
                            .accessibilityHidden(sync.status != .syncing)
                            .accessibilityLabel("正在同步")
                    }
                    .animation(ShelfMotion.lift, value: sync.status == .syncing)
                } else if case let .error(message) = sync.status {
                    Text(message).foregroundStyle(ShelfTheme.warning)
                }
                Text("只同步收藏、钉板和片段，普通历史不会离开这台 Mac")
                    .foregroundStyle(.secondary)
            }
            if sync.isEnabled {
                Section("其他设备") {
                    if sync.otherDevices.isEmpty {
                        Text("尚未发现其他设备").foregroundStyle(.secondary)
                    }
                    ForEach(sync.otherDevices) { device in
                        LabeledContent(device.name) {
                            Text(device.updatedAt, format: .dateTime.month().day().hour().minute().second())
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("选择")
        let iCloud = URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        panel.directoryURL = sync.folder ?? iCloud
        panel.begin { response in
            if response == .OK, let folder = panel.url { sync.selectFolder(folder) }
        }
    }
}

struct ShelfSyncStatus: View {
    let status: SyncEngine.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the arrows come to rest after a sync; they finish the turn instead of snapping back.
    @State private var restingAngle: Double = 0
    @State private var startedAt = Date.now

    var body: some View {
        let syncing = status == .syncing && !reduceMotion
        TimelineView(.animation(paused: !syncing)) { context in
            Image(systemName: failed ? "exclamationmark.icloud" : "arrow.triangle.2.circlepath")
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(syncing ? angle(at: context.date) : restingAngle))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(failed ? ShelfTheme.warning : .secondary)
        .animation(ShelfMotion.lift, value: failed)
        .onChange(of: syncing) { _, isSyncing in
            if isSyncing {
                startedAt = .now
                restingAngle = 0
            } else if reduceMotion {
                restingAngle = 0
            } else {
                // Continue forward to the next full turn so the stop reads as landing, not rewinding.
                let current = angle(at: .now)
                restingAngle = current
                withAnimation(ShelfMotion.glide) { restingAngle = ShelfMotionSpec.restingAngle(after: current) }
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var failed: Bool {
        if case .error = status { return true }
        return false
    }

    private var label: String {
        switch status {
        case .idle: L("同步待命")
        case .syncing: L("正在同步")
        case let .synced(date): L("上次同步 %@", date.formatted(date: .abbreviated, time: .shortened))
        case let .error(message): message
        }
    }

    /// Angle since this sync started, so every sync begins upright.
    private func angle(at date: Date) -> Double {
        let period = ShelfMotion.syncRotationPeriod
        return date.timeIntervalSince(startedAt) / period * 360
    }
}
