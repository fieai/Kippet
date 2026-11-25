import AppKit
import ApplicationServices
import SwiftUI

extension ShelfDelegate {
    func prepareUsageGuide() -> Bool {
        switch ShelfGuideLaunch(
            isCompleted: preferences.hasCompletedUsageGuide, hasHistory: !store.clips.isEmpty
        ) {
        case .skip:
            return false
        case .markCompleted:
            preferences.hasCompletedUsageGuide = true
            return false
        case .show:
            return true
        }
    }

    @objc func showUsageGuide() {
        if status.shelfIsOpen { hideShelf(restoreApplication: false) }
        if usageGuideWindow == nil {
            let content = ShelfUsageGuide(preferences: preferences) { [weak self] in
                guard let self else { return }
                preferences.hasCompletedUsageGuide = true
                usageGuideWindow?.close()
                showShelf()
            }
            let guide = NSWindow(contentViewController: NSHostingController(rootView: content))
            guide.title = L("使用引导")
            guide.styleMask = [.titled, .closable]
            guide.isReleasedWhenClosed = false
            guide.center()
            usageGuideWindow = guide
        }
        NSApp.activate()
        usageGuideWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct ShelfUsageGuide: View {
    let preferences: ShelfPreferences
    let onFinish: () -> Void

    @Environment(\.appearsActive) private var appearsActive
    @State private var clipboardStatus = L("复制一条内容试试")
    @State private var offersClipboardSettings = false
    @State private var hasAccessibilityAccess = false

    private static let clipboardSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"
    )!
    private static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kippet 在本机保存剪贴板历史，方便你找回并粘贴复制过的内容。")
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("呼出快捷键")
                    Text(preferences.shortcut(for: .showShelf).label)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("剪贴板读取")
                    Text(clipboardStatus).foregroundStyle(.secondary)
                    if offersClipboardSettings {
                        Button("去授权") { NSWorkspace.shared.open(Self.clipboardSettings) }
                            .accessibilityLabel("去授权剪贴板读取")
                    }
                }
                GridRow {
                    Text("辅助功能")
                    Text(hasAccessibilityAccess ? L("已允许") : L("未授权")).foregroundStyle(.secondary)
                    if !hasAccessibilityAccess {
                        Button("去授权") { NSWorkspace.shared.open(Self.accessibilitySettings) }
                            .accessibilityLabel("去授权辅助功能")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShelfTheme.cardFill, in: RoundedRectangle(cornerRadius: ShelfTheme.cardRadius))
            // Coming back from System Settings, newly granted access settles in instead of blinking.
            .animation(ShelfMotion.lift, value: hasAccessibilityAccess)
            .animation(ShelfMotion.lift, value: clipboardStatus)
            .animation(ShelfMotion.lift, value: offersClipboardSettings)

            Button("开始使用", action: onFinish)
                .buttonStyle(.borderedProminent)
                .tint(ShelfTheme.accent)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: appearsActive, initial: true) { _, active in
            if active { refreshPermissions() }
        }
    }

    private func refreshPermissions() {
        hasAccessibilityAccess = AXIsProcessTrusted()
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .default:
                clipboardStatus = L("尚未请求，复制一条内容试试")
                offersClipboardSettings = false
            case .ask:
                clipboardStatus = L("访问时询问")
                offersClipboardSettings = true
            case .alwaysAllow:
                clipboardStatus = L("已允许")
                offersClipboardSettings = false
            case .alwaysDeny:
                clipboardStatus = L("已拒绝")
                offersClipboardSettings = true
            @unknown default:
                clipboardStatus = L("复制一条内容试试")
                offersClipboardSettings = false
            }
        }
    }
}
