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

    /// What's just before the cursor, as far as the focused app will say.
    enum TextBefore: Equatable {
        case unknown
        case startOfField
        case character(Character)
    }

    private let clipboard = ClipboardSwap()
    private var lastPasteApp: pid_t?
    private var lastPasteTime = Date.distantPast

    public init() {}

    public func insert(_ text: String, restoreClipboard: Bool) -> Outcome {
        guard AXIsProcessTrusted() else {
            // Never restore here: the clipboard is the only copy of the text.
            clipboard.put(text, willRestore: false)
            return .copiedOnly
        }
        let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recentlyPastedHere = app != nil && app == lastPasteApp && Date().timeIntervalSince(lastPasteTime) < 300
        let before = Self.textBeforeCursor()
        let addSpace = Self.needsSpace(before: before, adding: text, recentlyPastedHere: recentlyPastedHere)
        clipboard.put(text, willRestore: restoreClipboard)
        // Typed rather than pasted, because terminals can strip a space from the start of a paste.
        if addSpace { Self.sendSpace() }
        Self.sendPaste()
        lastPasteApp = app
        lastPasteTime = Date()
        if restoreClipboard {
            // Apps read the clipboard some time after Cmd-V, so wait before swapping back.
            let clipboard = self.clipboard
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { clipboard.restore() }
        }
        return .pasted
    }

    /// Keeps dictations from running together, without doubling spaces. Some apps won't
    /// share the text around the cursor, so then it goes by whether we just pasted there.
    static func needsSpace(before: TextBefore, adding text: String, recentlyPastedHere: Bool) -> Bool {
        if let first = text.first, first.isWhitespace || ".,!?;:)]}".contains(first) { return false }
        switch before {
        case .startOfField:
            return false
        case .character(let character):
            return !character.isWhitespace && !"([{\"'“‘".contains(character)
        case .unknown:
            return recentlyPastedHere
        }
    }

    /// Reads one character only, and keeps nothing.
    private static func textBeforeCursor() -> TextBefore {
        let system = AXUIElementCreateSystemWide()
        // An app that's stuck must not hold up the paste.
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)

        var selection: CFTypeRef?
        var selected = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
              AXValueGetValue(selection as! AXValue, .cfRange, &selected) else { return .unknown }
        guard selected.location > 0 else { return .startOfField }

        var previous = CFRange(location: selected.location - 1, length: 1)
        var character: CFTypeRef?
        guard let range = AXValueCreate(.cfRange, &previous),
              AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         range, &character) == .success,
              let string = character as? String, let last = string.last else { return .unknown }
        return .character(last)
    }

    private static func sendSpace() {
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(kVK_Space)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cgSessionEventTap)
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
