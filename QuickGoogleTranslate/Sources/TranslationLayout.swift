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
    // Decode structural HTML locally. Copied images/CSS never reach a renderer.
    static func fromClipboard(_ clipboard: NSPasteboard) -> NSAttributedString? {
        if let data = clipboard.data(forType: .rtf), data.count < 1_000_000,
           let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return text }
        guard let data = clipboard.data(forType: .html), data.count < 1_000_000,
              let html = String(data: data, encoding: .utf8) else { return nil }
        let clean = sanitizeHTML(html)
        return parseHTML(clean)
    }
    // Tolerant, resource-free tokenizer. No WebKit, HTML importing service or
    // nested event loop runs while the shortcut handler owns a clipboard snapshot.
    static func parseHTML(_ html: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let tokenizer = try! NSRegularExpression(pattern: #"(?is)<\s*(/?)\s*([a-z][a-z0-9]*)\b[^>]*>|[^<]+|<"#)
        var strong = 0, italic = 0, code = 0, pre = 0
        var lists: [(ordered: Bool, count: Int)] = []
        func append(_ text: String) {
            var font = code > 0 || pre > 0 ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : NSFont.systemFont(ofSize: 15)
            if strong > 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic > 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            output.append(NSAttributedString(string: text, attributes: [.font: font]))
        }
        func boundary(_ count: Int = 1) {
            guard output.length > 0 else { return }
            let existing = output.string.reversed().prefix { $0 == "\n" }.count
            if existing < count { append(String(repeating: "\n", count: count - existing)) }
        }
        for match in tokenizer.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            if output.length > 20000 { break }
            guard let range = Range(match.range, in: html) else { continue }
            if let nameRange = Range(match.range(at: 2), in: html) {
                let name = html[nameRange].lowercased()
                let closing = match.range(at: 1).length > 0
                let delta = closing ? -1 : 1
                switch name {
                case "b", "strong", "h1", "h2", "h3", "h4", "h5", "h6":
                    if name.hasPrefix("h") { boundary() }
                    strong = max(0, strong + delta)
                case "i", "em": italic = max(0, italic + delta)
                case "code": code = max(0, code + delta)
                case "pre": boundary(); pre = max(0, pre + delta)
                case "br": append("\n")
                case "p": boundary(2)
                case "div", "blockquote", "tr": boundary()
                case "td", "th": if closing { append("\t") }
                case "ol", "ul":
                    boundary()
                    if closing { if !lists.isEmpty { lists.removeLast() } }
                    else { lists.append((name == "ol", 0)) }
                case "li":
                    boundary()
                    if !closing {
                        var marker = "• "
                        if !lists.isEmpty {
                            lists[lists.count - 1].count += 1
                            if lists.last!.ordered { marker = String(lists.last!.count) + ". " }
                        }
                        append(String(repeating: "  ", count: max(0, lists.count - 1)) + marker)
                    }
                default: break
                }
            } else {
                var text = decodeHTMLText(String(html[range]))
                if pre == 0 {
                    text = text.replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
                    if output.length == 0 || output.string.last?.isWhitespace == true {
                        if text.hasPrefix(" ") { text.removeFirst() }
                    }
                }
                append(text)
            }
        }
        return output
    }
    static func decodeHTMLText(_ text: String) -> String {
        let named = ["&nbsp;": "\u{00a0}", "&bull;": "•", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”"]
        let regex = try! NSRegularExpression(pattern: #"&(?:#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let source = Range(match.range, in: text), let destination = Range(match.range, in: output) else { continue }
            let token = String(text[source])
            output.replaceSubrange(destination, with: named[token] ?? TranslationRequest.decodeEntities(token))
        }
        return output
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
    static func translationResult(_ text: String) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: display(nil, text: text, size: 19))
        for heading in ["常见释义", "Word meanings"] {
            guard let divider = text.range(of: "\n\n" + heading + "\n") else { continue }
            let start = NSRange(divider, in: text).location + 2
            let body = NSRange(location: start + (heading as NSString).length + 1,
                               length: output.length - start - (heading as NSString).length - 1)
            // Songti gives Chinese dictionary entries a distinct, readable serif face.
            let system = NSFont.systemFont(ofSize: 17)
            let descriptor = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
            let serif = NSFont(name: "Songti SC", size: 17)
                ?? NSFont(descriptor: descriptor, size: 17) ?? system
            output.addAttribute(.font, value: serif, range: body)
            output.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                  .foregroundColor: NSColor.secondaryLabelColor],
                                 range: NSRange(location: start, length: (heading as NSString).length))
            break
        }
        return output
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
