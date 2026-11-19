import Carbon
import CoreGraphics

@MainActor
enum KeyboardLayout {
    static func keyCode(for character: UniChar) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        return withExtendedLifetime(source) {
            var result = [UniChar](repeating: 0, count: 4)
            for key in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                let status = UCKeyTranslate(
                    layout, key, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
                    result.count, &length, &result
                )
                if status == noErr, length == 1, result[0] == character { return key }
            }
            return nil
        }
    }

    static var pasteKeyCode: CGKeyCode? { keyCode(for: 0x76) }

    static func sendPaste(to pid: pid_t) -> Bool {
        guard CGPreflightPostEventAccess(),
              let key = pasteKeyCode,
              let source = CGEventSource(stateID: .combinedSessionState),
              let press = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let release = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        press.flags = .maskCommand
        release.flags = []
        press.postToPid(pid)
        release.postToPid(pid)
        return true
    }
}
