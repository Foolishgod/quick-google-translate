import AppKit
import PDFKit

func check(_ condition: Bool, _ label: String) {
    guard condition else { fputs("FAIL: " + label + "\n", stderr); exit(1) }
    print("PASS: " + label)
}
let preview = "com.apple.Preview"
check(AccessibleSelection.empty.needsCopy(bundleIdentifier: preview), "Preview empty accessibility selection falls back to copying")
check(AccessibleSelection.unavailable.needsCopy(bundleIdentifier: preview), "Preview missing accessibility selection falls back to copying")
check(AccessibleSelection.text("selected PDF text").needsCopy(bundleIdentifier: preview), "Preview prefers the PDF document's copy action to an incomplete accessibility selection")
check(!AccessibleSelection.protectedInput.needsCopy(bundleIdentifier: preview), "Secure fields never trigger a copy fallback")
check(!AccessibleSelection.empty.needsCopy(bundleIdentifier: "com.apple.TextEdit"), "Empty ordinary editors still open manual input immediately")
check(!AccessibleSelection.text("word").needsCopy(bundleIdentifier: "com.apple.TextEdit"), "Ordinary single-line selections retain the direct accessibility path")
check(AccessibleSelection.text("one\ntwo").needsCopy(bundleIdentifier: "com.apple.TextEdit"), "Multiline selections retain rich clipboard formatting")
check(AccessibleSelection.text("word").needsCopy(bundleIdentifier: "com.google.Chrome", chromium: true), "Chrome retains its formatting-aware copy path")

let clipboard = NSPasteboard(name: .init("qgt-pdf-selection-" + UUID().uuidString))
defer { clipboard.releaseGlobally() }
clipboard.setString("unrelated old clipboard", forType: .string)
let oldCount = clipboard.changeCount
let original = SelectionClipboardSnapshot(clipboard)
check(clipboard.changeCount == oldCount, "Snapshotting does not change the clipboard")

// Generate a searchable PDF with AppKit's real PDF writer, then select only a
// substring using PDFKit. No user documents or the general clipboard are used.
let app = NSApplication.shared
final class PageView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: "Before PDF selection: bank\nSecond PDF paragraph.\nAfter selection.",
                           attributes: [.font: NSFont(name: "Helvetica", size: 18)!])
            .draw(in: NSRect(x: 30, y: 30, width: 460, height: 200))
    }
}
let view = PageView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
let pdf = PDFDocument(data: view.dataWithPDF(inside: view.bounds))!
let page = pdf.page(at: 0)!
let body = page.string!
let range = (body as NSString).range(of: "bank")
check(range.location != NSNotFound, "PDFKit fixture contains searchable PDF text")
let selection = page.selection(for: range)!
check(selection.string == "bank", "PDFKit selects only the requested word")
let rich = selection.attributedString!
let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
clipboard.clearContents(); clipboard.setData(data, forType: .rtf)
check(clipboard.data(forType: .rtf) == data, "PDFKit selection publishes valid rich-text data")
let copiedCount = clipboard.changeCount
let captured = CapturedClipboardSelection.read(clipboard)
check(captured?.text == "bank" && captured?.formatting != nil, "RTF-only PDF selection is captured without surrounding document text")
check(original.restore(clipboard, ifUnchangedSince: copiedCount) && clipboard.string(forType: .string) == "unrelated old clipboard", "Successful PDF copy restores the previous clipboard")

clipboard.clearContents(); clipboard.setData(Data("<p>First selected line</p><p>Second line</p>".utf8), forType: .html)
check(CapturedClipboardSelection.read(clipboard)?.text.contains("First selected line\n\nSecond line") == true, "HTML-only selection preserves paragraph boundaries")
clipboard.clearContents(); clipboard.setString("plain PDF selection", forType: .string)
check(CapturedClipboardSelection.read(clipboard)?.text == "plain PDF selection", "Plain-text PDF copying remains supported")
clipboard.clearContents(); clipboard.setString("fallback text", forType: .string); clipboard.setData(Data("{\\rtf1 }".utf8), forType: .rtf)
check(CapturedClipboardSelection.read(clipboard)?.text == "fallback text", "Empty rich text falls back to available plain text")
clipboard.clearContents(); clipboard.setData(Data([0x01,0x02]), forType: .tiff)
check(CapturedClipboardSelection.read(clipboard) == nil, "Image-only PDF copies never translate the previous clipboard or the whole PDF")
let imageCount = clipboard.changeCount
check(original.restore(clipboard, ifUnchangedSince: imageCount) && clipboard.string(forType: .string) == "unrelated old clipboard", "Image-only copy restores the previous clipboard too")
clipboard.clearContents(); clipboard.setString("new user copy", forType: .string)
check(!original.restore(clipboard, ifUnchangedSince: imageCount) && clipboard.string(forType: .string) == "new user copy", "A newer user clipboard change is not overwritten")
clipboard.clearContents(); clipboard.setString("  \n  ", forType: .string)
check(CapturedClipboardSelection.read(clipboard) == nil, "Whitespace copies do not become invalid translations")
print("All PDF selection checks passed; no user PDFs, general clipboard, permissions or preferences changed.")
