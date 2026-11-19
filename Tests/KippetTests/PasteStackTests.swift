import Foundation
import Testing
@testable import Kippet

@MainActor
struct PasteStackTests {
    @Test func advancesOnlyTheDispatchedHeadAndCanRestoreIt() throws {
        let stack = PasteStack()
        let clip = Clip(id: UUID(), payload: .link("https://example.org"), date: .now)
        #expect(stack.append([clip, clip]))
        let first = try #require(stack.next)
        let second = stack.entries[1]
        #expect(first.id != second.id)
        #expect(!stack.didSend(second.id))
        #expect(stack.entries.count == 2)
        #expect(stack.next?.id == first.id)
        #expect(stack.didSend(first.id))
        #expect(!stack.didSend(first.id))
        #expect(stack.entries.count == 1)
        #expect(stack.next?.id == second.id)
        stack.undoLastPaste()
        #expect(stack.entries.map(\.id) == [first.id, second.id])
        stack.move(second.id, by: -1)
        stack.remove(first.id)
        #expect(stack.entries.map(\.id) == [second.id])
        stack.isCollecting = true
        stack.clear()
        #expect(!stack.isCollecting)
        #expect(stack.entries.isEmpty)
    }
}
