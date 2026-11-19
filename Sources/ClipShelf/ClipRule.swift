import Foundation

enum DetectedKind: String, CaseIterable, Codable, Sendable {
    case color, code, oneTimeCode, email, phone

    var label: String {
        switch self {
        case .color: "颜色"
        case .code: "代码"
        case .oneTimeCode: "验证码"
        case .email: "邮箱"
        case .phone: "电话"
        }
    }
}

extension DetectedContent {
    var kind: DetectedKind {
        switch self {
        case .color: .color
        case .code: .code
        case .oneTimeCode: .oneTimeCode
        case .email: .email
        case .phone: .phone
        }
    }
}

struct ClipRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var match: Match
    var action: Action

    struct Match: Codable, Equatable, Sendable {
        var sourceBundleIdentifiers: [String]?
        var kinds: [ClipKind]?
        var detected: [DetectedKind]?
        var textContains: String?
        var regex: String?

        var hasInvalidRegex: Bool {
            regex.map { (try? NSRegularExpression(pattern: $0)) == nil } ?? false
        }
    }

    enum Action: Codable, Equatable, Sendable {
        case addToGroup(UUID)
        case favorite
        case expire(after: TimeInterval)
        case skip

        var groupID: UUID? {
            if case let .addToGroup(id) = self { return id }
            return nil
        }
    }

    static let colorPresetID = UUID(uuidString: "B8B5E0DB-884E-42C9-9301-4804AAFCB167")!
    static let presets: [Self] = [
        Self(
            id: UUID(uuidString: "21B65C24-F9C4-4E45-BC1C-FAC5ACCE2736")!,
            name: "验证码 2 分钟后删除", isEnabled: true,
            match: Match(detected: [.oneTimeCode]), action: .expire(after: 120)
        ),
        Self(
            id: UUID(uuidString: "433EDFA3-0239-433D-BF33-8ED4DC5F6A53")!,
            name: "密码管理器内容不记录", isEnabled: true,
            match: Match(sourceBundleIdentifiers: [
                "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
            ]),
            action: .skip
        ),
        // The preset ID also stands in for the pinboard ID until a board is assigned on enable.
        Self(
            id: colorPresetID, name: "颜色归入『颜色』钉板", isEnabled: false,
            match: Match(detected: [.color]), action: .addToGroup(colorPresetID)
        ),
    ]
}

enum RuleEngine {
    static func actions(for clip: Clip, detected: DetectedContent?, rules: [ClipRule]) -> [ClipRule.Action] {
        var actions: [ClipRule.Action] = []
        for rule in rules where rule.isEnabled && matches(rule.match, clip: clip, detected: detected?.kind) {
            if rule.action == .skip { return [.skip] }
            if case let .expire(after: duration) = rule.action, !(60...604_800).contains(duration) { continue }
            actions.append(rule.action)
        }
        return actions
    }

    static func actions(
        for clip: Clip, detected: DetectedContent?, rules: [ClipRule], groupIDs: Set<ClipGroup.ID>
    ) -> [ClipRule.Action] {
        actions(for: clip, detected: detected, rules: rules.filter { rule in
            rule.action.groupID.map(groupIDs.contains) ?? true
        })
    }

    private static func matches(_ match: ClipRule.Match, clip: Clip, detected: DetectedKind?) -> Bool {
        if let sources = match.sourceBundleIdentifiers, clip.sourceBundleIdentifier.map(sources.contains) != true {
            return false
        }
        if let kinds = match.kinds, !kinds.contains(clip.payload.kind) { return false }
        if let types = match.detected, detected.map(types.contains) != true { return false }
        guard match.textContains != nil || match.regex != nil else { return true }

        let text: String
        switch clip.payload {
        case let .text(value, _, _), let .link(value): text = value
        case .image, .files: return false
        }
        if let fragment = match.textContains, text.range(of: fragment, options: .caseInsensitive) == nil { return false }
        if let pattern = match.regex {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        }
        return true
    }
}
