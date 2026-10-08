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
let dictionary = Data(#"[[["银行","bank"]],[["noun",["银行","岸","银行","堤"]],["verb",["存款","倾斜"]]],"en"]"#.utf8)
check(TranslationRequest.isSingleWord("bank") && TranslationRequest.isSingleWord("mother-in-law") && TranslationRequest.isSingleWord("café") && TranslationRequest.isSingleWord("银行"), "recognize single words including hyphens and accents")
check(!TranslationRequest.isSingleWord("two words") && !TranslationRequest.isSingleWord("hello!") && !TranslationRequest.isSingleWord(""), "sentences and empty input do not trigger dictionary lookup")
let meanings = TranslationRequest.dictionaryMeanings(dictionary, target: "zh-CN")
check(meanings == ["名词 · 银行；岸；堤", "动词 · 存款；倾斜"], "show multiple meanings grouped by part of speech and remove duplicates")
check(TranslationRequest.withMeanings("银行", meanings: meanings, target: "zh-CN").contains("常见释义"), "append a labeled dictionary section")
check(TranslationRequest.dictionaryMeanings(Data("[null,null]".utf8), target: "en").isEmpty, "missing dictionary does not break translation")
check(TranslationRequest.dictionaryMeanings(Data("invalid".utf8), target: "en").isEmpty, "invalid dictionary fails softly")
check(TranslationRequest.withMeanings("hello", meanings: [], target: "en") == "hello", "keep successful translation when dictionary is unavailable")
let requestURL = TranslationRequest.publicURL(text: "中文 & test", source: "zh-CN", target: "en", dictionary: true)
let requestItems = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)!.queryItems!
check(requestItems.first { $0.name == "sl" }?.value == "zh-CN" && requestItems.first { $0.name == "tl" }?.value == "en", "Chinese to English uses explicit source and target")
check(requestItems.filter { $0.name == "dt" }.map(\.value) == ["t", "bd"], "request translation and dictionary without Cloud credentials")
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
