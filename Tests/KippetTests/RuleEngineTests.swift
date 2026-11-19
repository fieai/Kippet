import Foundation
import Testing
@testable import Kippet

struct RuleEngineTests {
    private let clip = Clip(
        id: UUID(), payload: .text("Figma draft 42", rtf: nil, html: nil), date: .now,
        sourceName: "Figma", sourceBundleIdentifier: "com.figma.Desktop"
    )

    @Test func matchesAnySourceBundleIdentifier() {
        #expect(matches(.init(sourceBundleIdentifiers: ["com.apple.Notes", "com.figma.Desktop"])))
        #expect(!matches(.init(sourceBundleIdentifiers: ["Figma"])))
    }

    @Test func matchesAnyPayloadKind() {
        #expect(matches(.init(kinds: [.image, .text])))
        #expect(!matches(.init(kinds: [.image, .link])))
    }

    @Test(arguments: [
        (DetectedContent.color(red: 0, green: 0, blue: 0, alpha: 1, original: "#000000"), DetectedKind.color),
        (.code(language: .swift), .code),
        (.oneTimeCode("482913"), .oneTimeCode),
        (.email("hello@example.com"), .email),
        (.phone("13800138000"), .phone),
    ])
    func matchesAnyDetectedKind(_ fixture: (DetectedContent, DetectedKind)) {
        let other = DetectedKind.allCases.filter { $0 != fixture.1 }
        let condition = ClipRule.Match(detected: [other[0], fixture.1])
        #expect(matches(condition, detected: fixture.0))
        #expect(!matches(condition))
        #expect(!matches(.init(detected: other), detected: fixture.0))
    }

    @Test func containsTextCaseInsensitively() {
        #expect(matches(.init(textContains: "FIGMA DraFt")))
        #expect(!matches(.init(textContains: "Figma final")))
    }

    @Test func matchesRegularExpressions() {
        #expect(matches(.init(regex: #"draft\s+\d+$"#)))
        #expect(!matches(.init(regex: #"final\s+\d+$"#)))
        #expect(!matches(.init(regex: "^figma")))
    }

    @Test func textConditionsUseLinkTextAndIgnoreImagePlaceholders() {
        var link = clip
        link.payload = .link("https://example.com/draft")
        let textRules = [rule(.init(textContains: "EXAMPLE"), .favorite), rule(.init(regex: "/draft$"), .skip)]
        #expect(RuleEngine.actions(for: link, detected: nil, rules: textRules) == [.skip])

        var image = clip
        image.payload = .image(Data(), format: "public.png")
        #expect(RuleEngine.actions(for: image, detected: nil, rules: [rule(.init(textContains: "图片"), .skip)]).isEmpty)
    }

    @Test func allProvidedConditionsMustMatch() {
        let detected = DetectedContent.code(language: nil)
        var condition = ClipRule.Match(
            sourceBundleIdentifiers: ["com.figma.Desktop"], kinds: [.text],
            detected: [.code], textContains: "DRAFT", regex: #"\d+$"#
        )
        #expect(matches(condition, detected: detected))
        condition.sourceBundleIdentifiers = ["com.apple.Notes"]
        #expect(!matches(condition, detected: detected))
        condition.sourceBundleIdentifiers = nil
        #expect(matches(condition, detected: detected))
        #expect(!matches(condition))
    }

    @Test func skipOverridesEarlierAndLaterActions() {
        let rules = [rule(.init(), .favorite), rule(.init(), .skip), rule(.init(), .expire(after: 60))]
        #expect(RuleEngine.actions(for: clip, detected: nil, rules: rules) == [.skip])
    }

    @Test func returnsOtherActionsInListOrder() {
        let expected: [ClipRule.Action] = [.expire(after: 60), .favorite, .expire(after: 604_800)]
        let rules = expected.map { rule(.init(), $0) }
        #expect(RuleEngine.actions(for: clip, detected: nil, rules: rules) == expected)
    }

    @Test func invalidRegexNeverMatches() {
        let match = ClipRule.Match(regex: "[")
        #expect(match.hasInvalidRegex)
        #expect(!matches(match))
        #expect(!ClipRule.Match(regex: #"\d+"#).hasInvalidRegex)
    }

    @Test func disabledRuleIsIgnored() {
        var disabled = rule(.init(), .skip)
        disabled.isEnabled = false
        #expect(RuleEngine.actions(for: clip, detected: nil, rules: [disabled, rule(.init(), .favorite)]) == [.favorite])
    }

    @Test func deletedGroupRuleIsIgnored() {
        let existing = UUID()
        let deleted = UUID()
        let rules = [rule(.init(), .addToGroup(deleted)), rule(.init(), .addToGroup(existing))]
        #expect(RuleEngine.actions(for: clip, detected: nil, rules: rules, groupIDs: [existing]) == [.addToGroup(existing)])
    }

    @Test func outOfRangeExpiryActionsAreIgnored() {
        let rules = [rule(.init(), .expire(after: 59)), rule(.init(), .expire(after: 604_801))]
        #expect(RuleEngine.actions(for: clip, detected: nil, rules: rules).isEmpty)
    }

    @Test func presetsExpireDetectedCodesSkipPasswordManagersAndLeaveColorsAlone() {
        let text = "验证码 482913"
        var sample = clip
        sample.payload = .text(text, rtf: nil, html: nil)
        let detected = ContentDetector.detect(text)
        #expect(detected == .oneTimeCode("482913"))
        #expect(RuleEngine.actions(for: sample, detected: detected, rules: ClipRule.presets) == [.expire(after: 120)])

        for source in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords"] {
            sample.sourceBundleIdentifier = source
            #expect(RuleEngine.actions(for: sample, detected: detected, rules: ClipRule.presets) == [.skip])
        }
        sample.sourceBundleIdentifier = nil
        let color = ContentDetector.detect("#14B8A6")
        #expect(RuleEngine.actions(for: sample, detected: color, rules: ClipRule.presets).isEmpty)
    }

    private func matches(_ match: ClipRule.Match, detected: DetectedContent? = nil) -> Bool {
        RuleEngine.actions(for: clip, detected: detected, rules: [rule(match, .favorite)]) == [.favorite]
    }

    private func rule(_ match: ClipRule.Match, _ action: ClipRule.Action) -> ClipRule {
        ClipRule(id: UUID(), name: "测试规则", isEnabled: true, match: match, action: action)
    }
}
