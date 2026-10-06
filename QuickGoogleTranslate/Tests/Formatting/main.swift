import AppKit

func check(_ condition: Bool, _ message: String) { precondition(condition, message); print("PASS: " + message) }
let source = "• UGTA Debugger: first rule.\n• AI Cannon: second rule with CANNON_RANGE.\n\n  1. Third rule\n\t2. Fourth rule\n\n```python\ndef plant_plan(board):\n    return board\n```"
let plan = TranslationLayout(source)
check(plan.requests == ["UGTA Debugger: first rule.", "AI Cannon: second rule with CANNON_RANGE.", "Third rule", "Fourth rule"], "translate content while retaining bullets, indentation and code")
let output = plan.assemble(["调试器：第一条。", "大炮：第二条 CANNON_RANGE。", "第三条", "第四条"])
check(output == "• 调试器：第一条。\n• 大炮：第二条 CANNON_RANGE。\n\n  1. 第三条\n\t2. 第四条\n\n```python\ndef plant_plan(board):\n    return board\n```", "preserve list numbering, blank paragraphs, indentation and code verbatim")
check(TranslationLayout("one line").requests.count == 1, "plain sentences still use a single request")
check(TranslationLayout("return to the main page\nclass of students").requests.count == 2, "ordinary prose is not mistaken for a code declaration")
check(TranslationLayout("A\r\n\r\nB").assemble(["甲", "乙"]) == "甲\n\n乙", "retain paragraph boundaries across CRLF input")
let html = "<head><link href='https://example.invalid/x'></head><ul><li><b>UGTA Debugger:</b> first rule</li><li><strong>AI Cannon:</strong> <code>CANNON_RANGE</code></li></ul><img src='https://example.invalid/a'><script>fetch('https://example.invalid/b')</script>"
let sanitized = SelectionFormatting.sanitizeHTML(html)
check(!sanitized.contains("example.invalid") && !sanitized.contains("<script") && !sanitized.contains("src="), "HTML import strips all external resources and active content")
let board = NSPasteboard(name: NSPasteboard.Name("qgt-format-fixture-" + UUID().uuidString))
board.setData(Data(html.utf8), forType: .html)
let rich = SelectionFormatting.fromClipboard(board)!
check(rich.string.contains("UGTA Debugger:") && rich.string.contains("AI Cannon:") && rich.string.contains("\n"), "HTML list selection retains item boundaries")
let text = rich.string.trimmingCharacters(in: .whitespacesAndNewlines)
let styled = SelectionFormatting.display(rich, text: text, size: 15)
let labelRange = (text as NSString).range(of: "UGTA Debugger:")
let font = styled.attribute(.font, at: labelRange.location, effectiveRange: nil) as! NSFont
check(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "source bold label remains bold")
let translated = SelectionFormatting.display(nil, text: output, size: 19)
let token = (output as NSString).range(of: "CANNON_RANGE")
check((translated.attribute(.font, at: token.location, effectiveRange: nil) as! NSFont).isFixedPitch, "technical identifiers use a monospaced font")
let style = translated.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
check(style.headIndent > style.firstLineHeadIndent, "wrapped list items align below their text")
board.releaseGlobally()
print("All formatting checks passed; system clipboard and Google accounts unchanged.")
let service = TranslationService()
var units: [(String, (Result<String, Error>) -> Void)] = []
service.unitTranslatorForVerification = { text, _, complete in units.append((text, complete)) }
var completed: String?
service.translate(text: "• First\n\n  2. Second", target: "zh-CN") { result in if case .success(let value) = result { completed = value } }
check(units.map { $0.0 } == ["First"], "first structural unit is submitted once")
units[0].1(.success("第一条"))
check(units.map { $0.0 } == ["First", "Second"] && completed == nil, "second unit follows without returning incomplete output")
units[1].1(.success("第二条"))
check(completed == "• 第一条\n\n  2. 第二条", "service returns one correctly structured translation")
units = []; completed = nil
service.translate(text: "Old\nOld second", target: "zh-CN") { _ in preconditionFailure("Canceled document completed") }
let old = units[0].1
service.cancel()
service.translate(text: "New", target: "zh-CN") { result in if case .success(let value) = result { completed = value } }
old(.success("迟到旧结果"))
check(units.count == 2 && completed == nil, "old unit cannot append or start more requests after cancellation")
units[1].1(.success("新结果"))
check(completed == "新结果", "latest document completes independently")
var failed = false
units = []
service.translate(text: "A\nB\nC", target: "zh-CN") { result in if case .failure = result { failed = true } }
units[0].1(.success("甲")); units[1].1(.failure(TranslationError.message("fixture failure")))
check(failed && units.count == 2, "failed unit stops the document and does not return partial text")
print("All structural service checks passed; no network requests made.")
