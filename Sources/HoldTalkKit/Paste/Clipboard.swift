import AppKit

/// Puts text on a pasteboard, and can later put back what was there before.
public final class ClipboardSwap {
    private let pasteboard: NSPasteboard
    private var saved: [NSPasteboardItem] = []
    private var ownChangeCount = 0

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// `willRestore` also marks the text transient, so clipboard managers skip it.
    public func put(_ text: String, willRestore: Bool) {
        if willRestore { saved = Self.snapshot(pasteboard) }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if willRestore {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        ownChangeCount = pasteboard.changeCount
    }

    /// Does nothing if something new was copied in the meantime, because that's
    /// newer than what we saved.
    public func restore() {
        defer { saved = [] }
        guard pasteboard.changeCount == ownChangeCount else { return }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
