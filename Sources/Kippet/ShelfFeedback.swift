import Foundation

/// How a short footer message should look and how long it stays.
///
/// Confirmations get a check mark and leave on their own; anything that did not work (or needs the
/// person to do something) gets a warning glyph and stays long enough to read.
enum ShelfFeedback {
    enum Tone: Equatable, Sendable {
        case success, warning

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.circle.fill"
            }
        }

        /// Seconds before the message fades back to the keyboard hints.
        var lifetime: Double {
            switch self {
            case .success: 2.6
            case .warning: 5
            }
        }
    }

    /// Localized messages that report a failure or ask the person to do something.
    static var warnings: [String] {
        [
            L("已复制。请在原输入框按 ⌘V。"),
            L("剪贴板已变化，直接粘贴已取消。"),
            L("剪贴板已变化，本次操作已取消。"),
            L("授权直接粘贴后即可逐条贴出粘贴栈。"),
            L("粘贴栈已满，连续收集已停止。"),
            L("粘贴栈空间已满"),
            L("收藏空间已满"),
            L("没有可处理的内容"),
            L("复制失败"),
            L("图片尚未同步"),
            L("无法读取原图片。请右键卡片，选择「选取图片文件…」。"),
            L("无法拼接。请检查内容类型和大小。"),
            L("无法归入钉板，请检查卡片或收藏容量"),
            L("无法更新分组，请检查收藏空间"),
            L("无法补存这张图片。请检查文件是否可读及收藏空间。"),
            L("已新建分组，未能加入这张卡片"),
        ]
    }

    static func tone(for message: String, warnings: [String] = warnings) -> Tone {
        warnings.contains(message) ? .warning : .success
    }
}
