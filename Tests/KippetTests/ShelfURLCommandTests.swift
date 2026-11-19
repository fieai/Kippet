import Foundation
import Testing
@testable import Kippet

struct ShelfURLCommandTests {
    @Test func parsesSupportedCommands() throws {
        let examples: [(String, ShelfURLCommand)] = [
            ("kippet://open", .open),
            ("CLIPSHELF://STACK", .stack),
            ("KIPPET://STACK", .stack),
            ("clipshelf://search?q=old", .search("old")),
            ("kippet://search?q=hello%20%E6%8B%BE", .search("hello 拾")),
            ("kippet://search?q=C%2B%2B", .search("C++")),
            ("kippet://search", .search("")),
            ("kippet://snippet/new?text=A%0AB%26C&title=My%20Snippet&pinboard=Design%20Notes",
             .newSnippet(text: "A\nB&C", title: "My Snippet", pinboard: "Design Notes")),
            ("kippet://snippet/new", .newSnippet(text: "", title: "", pinboard: nil)),
            ("kippet://copy?index=1", .copy(index: 1)),
            ("kippet://copy?index=20", .copy(index: 20)),
        ]
        for (link, command) in examples {
            let url = try #require(URL(string: link))
            #expect(ShelfURLCommand(url: url) == command)
        }
    }

    @Test(arguments: [
        "https://open", "kippet:///open", "kippet://unknown", "kippet://open/search",
        "kippet://snippet", "kippet://snippet/other", "kippet://copy", "kippet://copy?index=0",
        "kippet://copy?index=-1", "kippet://copy?index=1.5", "kippet://copy?index=abc",
        "kippet://copy?index=999999999999999999999999", "kippet://user@open",
    ])
    func ignoresUnknownAndInvalidCommands(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(ShelfURLCommand(url: url) == nil)
    }
}
