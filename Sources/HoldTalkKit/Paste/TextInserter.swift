import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Types the text into the focused app using the clipboard and Cmd-V.
@MainActor
public final class TextInserter {
    public enum Outcome: Equatable {
        case pasted
        /// No Accessibility permission, so the text is left on the clipboard.
        case copiedOnly
    }

    private let clipboard = ClipboardSwap()

    public init() {}

    public func insert(_ text: String, restoreClipboard: Bool) -> Outcome {
        guard AXIsProcessTrusted() else {
            // Never restore here: the clipboard is the only copy of the text.
            clipboard.put(text, willRestore: false)
            return .copiedOnly
        }
        clipboard.put(text, willRestore: restoreClipboard)
        Self.sendPaste()
        if restoreClipboard {
            // Apps read the clipboard some time after Cmd-V, so wait before swapping back.
            let clipboard = self.clipboard
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { clipboard.restore() }
        }
        return .pasted
    }

    private static func sendPaste() {
        // A private source, so keys still physically held can't change the shortcut.
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(keyCodeForV())
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Where "v" sits on the current keyboard layout, so Dvorak and others paste correctly.
    static func keyCodeForV() -> UInt16 {
        let fallback = UInt16(kVK_ANSI_V)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> UInt16 in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return fallback }
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, characters.count, &length, &characters)
                if status == noErr, length == 1, characters[0] == UniChar(UnicodeScalar("v").value) {
                    return code
                }
            }
            return fallback
        }
    }
}
