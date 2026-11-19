import Foundation
import Testing
@testable import ClipShelf

struct ShelfURLCommandTests {
    @Test func parsesSupportedCommands() throws {
        let examples: [(String, ShelfURLCommand)] = [
            ("clipshelf://open", .open),
            ("CLIPSHELF://STACK", .stack),
            ("clipshelf://search?q=hello%20%E6%8B%BE", .search("hello 拾")),
            ("clipshelf://search?q=C%2B%2B", .search("C++")),
            ("clipshelf://search", .search("")),
            ("clipshelf://snippet/new?text=A%0AB%26C&title=My%20Snippet&pinboard=Design%20Notes",
             .newSnippet(text: "A\nB&C", title: "My Snippet", pinboard: "Design Notes")),
            ("clipshelf://snippet/new", .newSnippet(text: "", title: "", pinboard: nil)),
            ("clipshelf://copy?index=1", .copy(index: 1)),
            ("clipshelf://copy?index=20", .copy(index: 20)),
        ]
        for (link, command) in examples {
            let url = try #require(URL(string: link))
            #expect(ShelfURLCommand(url: url) == command)
        }
    }

    @Test(arguments: [
        "https://open", "clipshelf:///open", "clipshelf://unknown", "clipshelf://open/search",
        "clipshelf://snippet", "clipshelf://snippet/other", "clipshelf://copy", "clipshelf://copy?index=0",
        "clipshelf://copy?index=-1", "clipshelf://copy?index=1.5", "clipshelf://copy?index=abc",
        "clipshelf://copy?index=999999999999999999999999", "clipshelf://user@open",
    ])
    func ignoresUnknownAndInvalidCommands(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(ShelfURLCommand(url: url) == nil)
    }
}
