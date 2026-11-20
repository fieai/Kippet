import Foundation
import Observation

@MainActor
@Observable
final class ShelfUpdateChecker {
    enum State: Equatable {
        case idle, checking, current, available(ShelfRelease), failed
    }

    private(set) var state = State.idle
    private let defaults = UserDefaults.standard
    private static let lastCheckKey = "lastUpdateCheck"

    func checkAutomatically(enabled: Bool) {
        if ShelfUpdateSchedule.isDue(
            enabled: enabled, lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date, now: .now
        ) {
            check()
        }
    }

    func check() {
        guard state != .checking else { return }
        guard let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let currentVersion = ShelfReleaseVersion(installedVersion) else {
            state = .failed
            return
        }
        state = .checking
        defaults.set(Date.now, forKey: Self.lastCheckKey)

        Task {
            do {
                let release = try await Self.fetchRelease()
                state = release.version > currentVersion ? .available(release) : .current
            } catch {
                state = .failed
            }
        }
    }

    private nonisolated static func fetchRelease() async throws -> ShelfRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let endpoint = URL(string: "https://api.github.com/repos/fieai/Kippet/releases/latest")!
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Kippet", forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ShelfRelease.self, from: data)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}
