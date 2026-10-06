import Foundation
import ApplicationServices

func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
func rejects(_ text: String) -> Bool {
    do { _ = try TranslationRequest.normalize(text); return false } catch { return true }
}
check(rejects("  \n\t"), "reject empty selections")
check(rejects(String(repeating: "中", count: 5001)), "enforce character limit")
check(try TranslationRequest.normalize("\n Hello \n世界 \n") == " Hello \n世界 ", "preserve multiline indentation and internal line breaks")
let input = "选中中文 & a+b? #\n第二行 😀"
let url = TranslationRequest.pageURL(text: input, target: "zh-TW")
let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
check(items.first(where: { $0.name == "text" })?.value == input, "encode multilingual text without losing URL characters")
check(items.first(where: { $0.name == "tl" })?.value == "zh-TW", "honor target language")
let payload = Data(#"[[["你好。","Hello.",null,null],["\n世界！","\nWorld!",null,null]],null,"en"]"#.utf8)
check(try TranslationRequest.parsePublicResponse(payload) == "你好。\n世界！", "join multi-sentence Google response")
let official = Data(#"{"data":{"translations":[{"translatedText":"A &amp; B &#39;x&#39; &#x1F600; &lt;tag&gt;"}]}}"#.utf8)
check(try TranslationRequest.parseOfficialResponse(official) == "A & B 'x' 😀 <tag>", "decode official response entities once")
check(TranslationRequest.decodeEntities("&amp;lt;") == "&lt;", "avoid double decoding")
do {
    _ = try TranslationRequest.parsePublicResponse(Data("[null]".utf8))
    fatalError("FAIL: malformed response must throw")
} catch { print("PASS: reject malformed Google response") }
check(AccessibilityPermission.isUsable(systemTrusted: true, externalProbe: nil), "accept confirmed OS permission")
check(AccessibilityPermission.isUsable(systemTrusted: false, externalProbe: .success), "accept a successful OS-authorized external read")
check(!AccessibilityPermission.isUsable(systemTrusted: false, externalProbe: .apiDisabled), "reject denied accessibility access")
check(!AccessibilityPermission.isUsable(systemTrusted: false, externalProbe: .cannotComplete), "do not confuse an AX error with permission")
check(!AccessibilityPermission.isUsable(systemTrusted: false, externalProbe: nil), "do not infer permission without evidence")
print("All translation and permission checks passed.")
