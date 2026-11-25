import Foundation
import Testing
@testable import Kippet

struct ShelfMotionSpecTests {
    @Test func repeatedActionsUseTheQuickestSprings() {
        let press = ShelfMotionSpec.spring(.press)
        let select = ShelfMotionSpec.spring(.select)
        #expect(press.response < select.response)
        for role in ShelfMotionSpec.Role.allCases where role != .press && role != .select {
            #expect(select.response < ShelfMotionSpec.spring(role).response)
        }
        for role in ShelfMotionSpec.Role.allCases {
            let spring = ShelfMotionSpec.spring(role)
            // Nothing in the shelf is allowed to wobble or drag on.
            #expect(spring.damping >= 0.7 && spring.damping <= 1)
            #expect(spring.response <= 0.4)
        }
    }

    @Test func onlyTheFrontCardsCascadeAndOnlyRightAfterAReveal() {
        #expect(ShelfMotionSpec.entranceAnimates(index: 0, secondsSinceReveal: 0))
        #expect(ShelfMotionSpec.entranceAnimates(index: ShelfMotionSpec.entranceCount - 1, secondsSinceReveal: 0.1))
        // A wide display shows more cards than the cascade has steps; they still fade in together.
        #expect(ShelfMotionSpec.entranceAnimates(index: ShelfMotionSpec.entranceCount + 2, secondsSinceReveal: 0))
        #expect(!ShelfMotionSpec.entranceAnimates(index: ShelfMotionSpec.entranceLimit, secondsSinceReveal: 0))
        #expect(!ShelfMotionSpec.entranceAnimates(index: 0, secondsSinceReveal: ShelfMotionSpec.entranceWindow))
        #expect(!ShelfMotionSpec.entranceAnimates(index: -1, secondsSinceReveal: 0))
        #expect(!ShelfMotionSpec.entranceAnimates(index: 0, secondsSinceReveal: -1))
    }

    @Test func cascadeDelaysGrowAndStayShort() {
        let first = ShelfMotionSpec.entranceDelay(for: 0)
        let second = ShelfMotionSpec.entranceDelay(for: 1)
        let last = ShelfMotionSpec.entranceDelay(for: ShelfMotionSpec.entranceCount - 1)
        #expect(first < second && second < last)
        #expect(ShelfMotionSpec.entranceDelay(for: 500) == last)
        #expect(last < 0.25)
        // Switching boards settles every card together.
        #expect(ShelfMotionSpec.entranceDelay(for: 5, cascade: false) == 0)
        #expect(ShelfMotionSpec.entranceRise(cascade: false) < ShelfMotionSpec.entranceRise(cascade: true))
    }

    @Test func reopeningMidDismissScalesToTheDistanceLeft() {
        #expect(ShelfMotionSpec.riseDuration(remainingFraction: 1) == ShelfMotionSpec.windowRiseDuration)
        #expect(ShelfMotionSpec.riseDuration(remainingFraction: 0.5) == ShelfMotionSpec.windowRiseDuration / 2)
        #expect(ShelfMotionSpec.riseDuration(remainingFraction: 0) == 0.12)
        #expect(ShelfMotionSpec.riseDuration(remainingFraction: 3) == ShelfMotionSpec.windowRiseDuration)
        #expect(ShelfMotionSpec.windowSinkDuration < ShelfMotionSpec.windowRiseDuration)
    }

    @Test func syncArrowsFinishTheirTurnForward() {
        #expect(ShelfMotionSpec.restingAngle(after: 0) == 0)
        #expect(ShelfMotionSpec.restingAngle(after: 10) == 360)
        #expect(ShelfMotionSpec.restingAngle(after: 360) == 360)
        #expect(ShelfMotionSpec.restingAngle(after: 361) == 720)
        #expect(ShelfMotionSpec.restingAngle(after: -.infinity) == 0)
        #expect(ShelfMotionSpec.restingAngle(after: .nan) == 0)
    }
}

struct ShelfFeedbackTests {
    @Test func failuresGetAWarningAndStayLonger() {
        #expect(ShelfFeedback.tone(for: L("已复制")) == .success)
        #expect(ShelfFeedback.tone(for: L("已加入「%@」", "工作")) == .success)
        #expect(ShelfFeedback.tone(for: L("收藏空间已满")) == .warning)
        #expect(ShelfFeedback.tone(for: L("已复制。请在原输入框按 ⌘V。")) == .warning)
        #expect(ShelfFeedback.tone(for: L("无法拼接。请检查内容类型和大小。")) == .warning)
        #expect(ShelfFeedback.Tone.warning.lifetime > ShelfFeedback.Tone.success.lifetime)
        #expect(ShelfFeedback.Tone.success.symbol != ShelfFeedback.Tone.warning.symbol)
    }

    @Test func matchesWhateverLanguageTheMessagesAreIn() {
        #expect(ShelfFeedback.tone(for: "Favorites are full", warnings: ["Favorites are full"]) == .warning)
        #expect(ShelfFeedback.tone(for: "收藏空间已满", warnings: ["Favorites are full"]) == .success)
    }

    @Test func everyWarningIsAMessageTheAppActuallyShows() throws {
        // Guards against a message being reworded at its call site while this list keeps the old wording.
        let sources = try ShelfSourceText.all()
        for warning in ShelfFeedback.warnings {
            #expect(sources.contains("\"\(warning)\""), "\(warning) is not used in Sources")
        }
    }
}

/// Reads the app's Swift sources so tests can check that copy referenced elsewhere still exists.
enum ShelfSourceText {
    static func all() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Kippet")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ShelfFeedback.swift" }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }
}
