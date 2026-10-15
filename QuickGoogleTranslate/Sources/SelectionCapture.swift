import AppKit

enum AccessibleSelection {
    case text(String)
    case empty
    case unavailable
    case protectedInput

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    func needsCopy(bundleIdentifier: String?, chromium: Bool = false) -> Bool {
        switch self {
        case .protectedInput: return false
        // Preview's focused accessibility element can report an empty selection
        // while its PDF document still has selected, copyable text.
        case .empty: return bundleIdentifier == "com.apple.Preview"
        case .unavailable: return true
        case .text(let text):
            return bundleIdentifier == "com.apple.Preview" || chromium || text.contains("\n")
        }
    }
}

struct CapturedClipboardSelection {
    let text: String
    let formatting: NSAttributedString?

    static func read(_ clipboard: NSPasteboard) -> CapturedClipboardSelection? {
        // PDF readers can publish RTF without a plain-text representation.
        if let rich = SelectionFormatting.fromClipboard(clipboard),
           !rich.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CapturedClipboardSelection(text: rich.string, formatting: rich)
        }
        guard let text = clipboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CapturedClipboardSelection(text: text, formatting: nil)
    }
}

struct SelectionClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init(_ clipboard: NSPasteboard) {
        items = (clipboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }
    @discardableResult
    func restore(_ clipboard: NSPasteboard, ifUnchangedSince changeCount: Int) -> Bool {
        guard clipboard.changeCount == changeCount else { return false }
        clipboard.clearContents()
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { clipboard.writeObjects(restored) }
        return true
    }
}
