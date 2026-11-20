import AppKit
import Foundation
import Testing
@testable import Kippet

struct ShelfPollingStateTests {
    @Test func requiresEveryStopConditionToBeClear() {
        for conditions in 0..<32 {
            let state = ShelfPollingState(
                screensAsleep: conditions & 1 != 0,
                systemAsleep: conditions & 2 != 0,
                screenLocked: conditions & 4 != 0,
                sessionInactive: conditions & 8 != 0
            )
            #expect(state.shouldPoll(isPaused: conditions & 16 != 0) == (conditions == 0))
        }
    }

    @Test func clearingSleepDoesNotResumeWhileLockedOrPaused() {
        var state = ShelfPollingState(screensAsleep: true, systemAsleep: true, screenLocked: true)
        state.systemAsleep = false
        #expect(!state.shouldPoll(isPaused: true))
        state.screensAsleep = false
        #expect(!state.shouldPoll(isPaused: false))
        state.screenLocked = false
        #expect(!state.shouldPoll(isPaused: true))
        #expect(state.shouldPoll(isPaused: false))
    }

    @Test @MainActor func storePauseChangesNotifyPollingWithoutClipboardContents() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "KippetPollingTests-\(UUID())")
        let suite = "KippetPollingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard.withUniqueName()
        let store = ClipboardStore(board: board, archiveURL: folder.appending(path: "History.plist"), preferences: defaults)
        defer {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        let state = ShelfPollingState()
        var decisions: [Bool] = []
        store.onCapturePauseChange = { [weak store] in
            if let store { decisions.append(state.shouldPoll(isPaused: store.isPaused)) }
        }
        store.toggleCapture()
        #expect(defaults.bool(forKey: "capturePaused"))
        store.toggleCapture()
        #expect(!defaults.bool(forKey: "capturePaused"))
        #expect(decisions == [false, true])
    }
}

struct ShelfReleaseTests {
    @Test func comparesVersionsBySemanticPrecedence() throws {
        let labels = [
            "1.2.9", "1.2.10", "1.10.0",
            "2.0.0-alpha", "2.0.0-alpha.1", "2.0.0-alpha.beta", "2.0.0-beta",
            "2.0.0-beta.2", "2.0.0-beta.11", "2.0.0-rc.1", "2.0.0",
            "99999999999999999999.0.0", "100000000000000000000.0.0",
        ]
        let versions = try labels.map { label in try #require(ShelfReleaseVersion(label)) }
        for (earlier, later) in zip(versions, versions.dropFirst()) {
            #expect(earlier < later)
            #expect(!(later < earlier))
        }
        let firstBuild = try #require(ShelfReleaseVersion("1.2.3+0001"))
        let secondBuild = try #require(ShelfReleaseVersion("1.2.3+build.2"))
        #expect(firstBuild == secondBuild)
    }

    @Test(arguments: ["", "1.2", "1.2.3.4", "01.2.3", "1.2.3-01", "1.2.3-alpha..1", "1.2.3+", "1.2.3\n"])
    func rejectsMalformedVersions(_ version: String) {
        #expect(ShelfReleaseVersion(version) == nil)
    }

    @Test(arguments: ["v1.10.0", "1.10.0"])
    func decodesTagAndDownloadURL(_ tag: String) throws {
        let json = Data("""
            {"tag_name":"\(tag)","html_url":"https://github.com/fieai/Kippet/releases/tag/\(tag)",
             "name":"Unrelated release title","other":{"ignored":true}}
            """.utf8)
        let release = try JSONDecoder().decode(ShelfRelease.self, from: json)
        let installed = try #require(ShelfReleaseVersion("1.9.0"))
        #expect(release.version > installed)
        #expect(release.versionLabel == "1.10.0")
        #expect(release.downloadURL.absoluteString == "https://github.com/fieai/Kippet/releases/tag/\(tag)")
    }

    @Test(arguments: [
        #"{}"#,
        #"{"tag_name":"latest","html_url":"https://github.com/fieai/Kippet/releases/latest"}"#,
        #"{"tag_name":"v1.2.3"}"#,
        #"{"tag_name":"v1.2.3","html_url":"http://github.com/fieai/Kippet/releases/latest"}"#,
        #"{"tag_name":"v1.2.3","html_url":"https://github.com.example.org/"}"#,
        #"{"tag_name":"v1.2.3","html_url":"https://user:secret@github.com/fieai/Kippet/"}"#,
    ])
    func rejectsInvalidReleaseResponses(_ response: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ShelfRelease.self, from: Data(response.utf8))
        }
    }

    @Test func automaticChecksRequireOptInAndTwentyFourHoursBetweenAttempts() {
        let lastCheck = Date(timeIntervalSince1970: 100_000)
        #expect(!ShelfUpdateSchedule.isDue(enabled: false, lastCheck: nil, now: lastCheck))
        #expect(ShelfUpdateSchedule.isDue(enabled: true, lastCheck: nil, now: lastCheck))
        #expect(!ShelfUpdateSchedule.isDue(enabled: true, lastCheck: lastCheck, now: lastCheck))
        #expect(!ShelfUpdateSchedule.isDue(
            enabled: true, lastCheck: lastCheck, now: lastCheck.addingTimeInterval(86_399)
        ))
        #expect(ShelfUpdateSchedule.isDue(
            enabled: true, lastCheck: lastCheck, now: lastCheck.addingTimeInterval(86_400)
        ))
    }
}

@MainActor
struct ShelfGuideTests {
    @Test func launchShowsGuideOnlyForAnEmptyHistoryWithoutCompletion() {
        #expect(ShelfGuideLaunch(isCompleted: false, hasHistory: false) == .show)
        #expect(ShelfGuideLaunch(isCompleted: false, hasHistory: true) == .markCompleted)
        #expect(ShelfGuideLaunch(isCompleted: true, hasHistory: false) == .skip)
        #expect(ShelfGuideLaunch(isCompleted: true, hasHistory: true) == .skip)
    }

    @Test func automaticUpdatesDefaultOffAndBothPreferencesPersist() throws {
        let suite = "KippetLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ShelfPreferences(defaults: defaults)
        #expect(!preferences.autoCheckUpdates)
        #expect(!preferences.hasCompletedUsageGuide)

        preferences.autoCheckUpdates = true
        preferences.hasCompletedUsageGuide = true
        let reopened = ShelfPreferences(defaults: defaults)
        #expect(reopened.autoCheckUpdates)
        #expect(reopened.hasCompletedUsageGuide)
    }
}
