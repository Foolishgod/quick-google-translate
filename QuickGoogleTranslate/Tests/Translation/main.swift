import Foundation

func check(_ value: Bool, _ label: String) { precondition(value, label); print("PASS: " + label) }
@MainActor func result(_ service: TranslationService, _ text: String, source: String = "en", target: String = "zh-CN") async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        service.translate(text: text, target: target, source: source) { continuation.resume(with: $0) }
    }
}
func payload(_ translation: String, _ meanings: [[Any]]? = nil) -> Data {
    try! JSONSerialization.data(withJSONObject: [[[translation]], meanings as Any? ?? NSNull(), "en"])
}
Task { @MainActor in
    let service = TranslationService()
    service.backendForVerification = "google"
    do {
        if CommandLine.arguments.contains("--live") {
            let bank = try await result(service, "bank")
            check(bank.contains("银行") && bank.contains("岸") && bank.contains("常见释义"), "real Google word translation contains multiple meanings")
            let english = try await result(service, "你好，世界", source: "zh-CN", target: "en")
            check(english.lowercased().contains("hello") && english.lowercased().contains("world"), "real service translates Chinese to English")
            print("Live ordinary Google translation checks passed; only fixed public examples were sent.")
            exit(0)
        }
        var captured: [URLRequest] = []
        service.requestLoaderForVerification = { request in
            captured.append(request)
            return (payload("银行", [["noun", ["银行", "岸"]], ["verb", ["存款"]]]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let word = try await result(service, "bank")
        check(word.contains("名词 · 银行；岸") && word.contains("动词 · 存款"), "service appends dictionary entries to the final word result")
        check(captured.count == 1, "ordinary single-word translation and meanings use one request")
        captured.removeAll()
        service.requestLoaderForVerification = { request in
            captured.append(request)
            let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
            return (payload("译文:" + value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let paragraph = try await result(service, "• First line\n  2. Second line", source: "zh-CN", target: "en")
        check(paragraph == "• 译文:First line\n  2. 译文:Second line", "multiple requests preserve paragraph structure")
        check(captured.allSatisfy { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return items.first { $0.name == "sl" }!.value == "zh-CN" && items.first { $0.name == "tl" }!.value == "en"
        }, "every structural unit keeps the explicit translation direction")
        let plain = try await result(service, "bank")
        check(plain == "译文:bank", "missing dictionary keeps the normal result without another request")
        // Simulate a successful browser result followed by an optional dictionary request.
        service.unitTranslatorForVerification = { _, _, complete in complete(.success("网页译文")) }
        service.requestLoaderForVerification = { _ in throw URLError(.timedOut) }
        let fallback = try await result(service, "bank")
        check(fallback == "网页译文", "dictionary timeout never discards successful browser translation")
        var dictionaryStarted = false
        var lateResult = false
        service.requestLoaderForVerification = { request in
            dictionaryStarted = true
            try? await Task.sleep(nanoseconds: 100_000_000)
            return (payload("银行", [["noun", ["银行", "岸"]]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        service.translate(text: "bank", target: "zh-CN") { _ in lateResult = true }
        while !dictionaryStarted { await Task.yield() }
        service.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(!lateResult, "canceled optional dictionary cannot return a late result")
        service.unitTranslatorForVerification = nil
        var oldStarted = false
        service.requestLoaderForVerification = { request in
            let text = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
            if text == "old" { oldStarted = true; try? await Task.sleep(nanoseconds: 100_000_000) }
            return (payload(text == "old" ? "旧结果" : "新结果"), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        service.translate(text: "old", target: "zh-CN") { _ in lateResult = true }
        while !oldStarted { await Task.yield() }
        let latest = try await result(service, "new")
        try await Task.sleep(nanoseconds: 150_000_000)
        check(latest == "新结果" && !lateResult, "latest translation ignores a canceled transport even when it returns success")
        print("All transport, dictionary and direction checks passed; no network or saved settings changed.")
        exit(0)
    } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}
RunLoop.main.run()
