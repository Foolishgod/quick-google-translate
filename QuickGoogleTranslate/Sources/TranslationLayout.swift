import AppKit

// Translate structural lines independently so Google cannot merge list items or
// paragraphs. Whitespace, numbering and code-only lines never go to the service.
struct TranslationLayout {
    struct Line {
        let prefix: String
        let text: String
        let suffix: String
        let translate: Bool
    }
    let lines: [Line]
    var requests: [String] { lines.filter { $0.translate }.map { $0.text } }
    init(_ source: String) {
        var inCode = false
        lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); return Line(prefix: "", text: raw, suffix: "", translate: false) }
            let declaration = (trimmed.hasPrefix("def ") || trimmed.hasPrefix("class ")) && trimmed.hasSuffix(":")
            let indentedReturn = raw.first?.isWhitespace == true && trimmed.hasPrefix("return ")
            let code = inCode || declaration || indentedReturn || trimmed.hasPrefix("//") || trimmed.hasPrefix("#include")
            if trimmed.isEmpty || code { return Line(prefix: "", text: raw, suffix: "", translate: false) }
            let pattern = #"^([\t ]*(?:(?:[•·▪◦●\-–*]|\d+[.)]|[A-Za-z][.)])\s+)?)"#
            let range = raw.range(of: pattern, options: .regularExpression)!
            let prefix = String(raw[range])
            let remainder = String(raw[range.upperBound...])
            let text = remainder.trimmingCharacters(in: .whitespaces)
            let suffix = String(remainder.suffix(remainder.count - remainder.trimmingCharacters(in: .whitespaces).count))
            return Line(prefix: prefix, text: text, suffix: suffix, translate: !text.isEmpty)
        }
    }
    func assemble(_ translations: [String]) -> String {
        var index = 0
        return lines.map { line in
            guard line.translate else { return line.text }
            defer { index += 1 }
            return line.prefix + translations[index].trimmingCharacters(in: .whitespacesAndNewlines) + line.suffix
        }.joined(separator: "\n")
    }
}

struct SelectionFormatting {
    // Only import resource-free structural HTML. Strip all attributes and unsafe
    // elements before AppKit sees it; copied images/CSS cannot make network calls.
    static func fromClipboard(_ clipboard: NSPasteboard) -> NSAttributedString? {
        if let data = clipboard.data(forType: .rtf), data.count < 1_000_000,
           let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return text }
        guard let data = clipboard.data(forType: .html), data.count < 1_000_000,
              let html = String(data: data, encoding: .utf8) else { return nil }
        let clean = sanitizeHTML(html)
        return try? NSAttributedString(data: Data(clean.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    }
    static func sanitizeHTML(_ html: String) -> String {
        let unsafe = #"(?is)<(script|style|iframe|object|svg|head)\b[^>]*>.*?</\1\s*>"#
        var body = html.replacingOccurrences(of: unsafe, with: "", options: .regularExpression)
        let tags = try! NSRegularExpression(pattern: #"(?is)<!--.*?-->|<\s*(/?)\s*([a-z][a-z0-9]*)\b[^>]*>"#)
        let allowed: Set<String> = ["p", "br", "div", "li", "ol", "ul", "blockquote", "pre", "code", "strong", "b", "em", "i", "u", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "td", "th", "span"]
        for match in tags.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            guard let full = Range(match.range, in: body) else { continue }
            let name = Range(match.range(at: 2), in: body).map { String(body[$0]).lowercased() } ?? ""
            let closing = Range(match.range(at: 1), in: body).map { String(body[$0]) } ?? ""
            body.replaceSubrange(full, with: allowed.contains(name) ? "<\(closing)\(name)>" : "")
        }
        return "<html><meta charset=\"utf-8\"><body>" + body + "</body></html>"
    }
    static func display(_ source: NSAttributedString?, text: String, size: CGFloat) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: output.length)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 5
        output.addAttributes([.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)
        if let source, let range = source.string.range(of: text) {
            let sourceRange = NSRange(range, in: source.string)
            source.enumerateAttribute(.font, in: sourceRange) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let traits = NSFontManager.shared.traits(of: font)
                let base = font.isFixedPitch ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : NSFont.systemFont(ofSize: size)
                let styled = NSFontManager.shared.convert(base, toHaveTrait: traits.intersection([.boldFontMask, .italicFontMask]))
                output.addAttribute(.font, value: styled, range: NSRange(location: range.location - sourceRange.location, length: range.length))
            }
        }
        // Keep technical identifiers readable in both the source and translation.
        let tokens = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b|`[^`\n]+`"#)
        for match in tokens.matches(in: text, range: full) { output.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .medium), range: match.range) }
        let lists = try! NSRegularExpression(pattern: #"(?m)^[\t ]*(?:[•·▪◦●\-–*]|\d+[.)]|[A-Za-z][.)])\s+[^\n]*"#)
        for match in lists.matches(in: text, range: full) {
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.headIndent = size; style.firstLineHeadIndent = 0
            output.addAttribute(.paragraphStyle, value: style, range: match.range)
            let line = (text as NSString).substring(with: match.range)
            if let colon = line.range(of: #"[:：]"#, options: .regularExpression), line.distance(from: line.startIndex, to: colon.upperBound) < 90 {
                let prefix = NSRange(line.startIndex..<colon.upperBound, in: line)
                output.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: NSRange(location: match.range.location, length: prefix.length))
            }
        }
        return output
    }
}
