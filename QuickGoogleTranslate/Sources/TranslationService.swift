import AppKit
import WebKit

struct TranslationRequest {
    static func normalize(_ raw: String) throws -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let value = lines.count > 1 ? lines.joined(separator: "\n") : normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TranslationError.message("请输入要翻译的文字。") }
        guard value.count <= 5000 else { throw TranslationError.message("文字太长，请输入 5,000 字以内的内容。") }
        return value
    }
    static func pageURL(text: String, target: String, source: String = "auto") -> URL {
        var c = URLComponents(string: "https://translate.google.com/")!
        c.queryItems = [URLQueryItem(name: "sl", value: source), URLQueryItem(name: "tl", value: target), URLQueryItem(name: "text", value: text), URLQueryItem(name: "op", value: "translate")]
        return c.url!
    }
    static func parsePublicResponse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [[Any]] else { throw TranslationError.message("未能获取译文，请重试。") }
        let text = segments.compactMap { $0.first as? String }.joined()
        guard !text.isEmpty else { throw TranslationError.message("未能获取译文，请重试。") }
        return text
    }
    static func decodeEntities(_ value: String) -> String {
        let entities = ["quot": "\"", "apos": "'", "amp": "&", "lt": "<", "gt": ">"]
        let regex = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|quot|apos|amp|lt|gt);")
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range(at: 1), in: value), let full = Range(match.range, in: result) else { continue }
            let entity = String(value[range])
            let replacement: String?
            if entity.hasPrefix("#x"), let n = UInt32(entity.dropFirst(2), radix: 16), let scalar = UnicodeScalar(n) { replacement = String(scalar) }
            else if entity.hasPrefix("#"), let n = UInt32(entity.dropFirst()), let scalar = UnicodeScalar(n) { replacement = String(scalar) }
            else { replacement = entities[entity] }
            if let replacement { result.replaceSubrange(full, with: replacement) }
        }
        return result
    }
    static func isSingleWord(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count <= 80 else { return false }
        return word.range(of: #"^\p{Latin}+(?:['’\-]\p{Latin}+)*$"#, options: .regularExpression) != nil ||
            word.range(of: #"^\p{Han}{1,8}$"#, options: .regularExpression) != nil
    }
    static func publicURL(text: String, source: String, target: String, dictionary: Bool) -> URL {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: source),
                       URLQueryItem(name: "tl", value: target), URLQueryItem(name: "dt", value: "t")]
        if dictionary { c.queryItems!.append(URLQueryItem(name: "dt", value: "bd")) }
        c.queryItems!.append(URLQueryItem(name: "q", value: text))
        return c.url!
    }
    static func dictionaryMeanings(_ data: Data, target: String) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any], root.count > 1,
              let groups = root[1] as? [[Any]] else { return [] }
        let names = ["noun": "名词", "verb": "动词", "adjective": "形容词", "adverb": "副词",
                     "pronoun": "代词", "preposition": "介词", "conjunction": "连词", "interjection": "感叹词"]
        var output: [String] = []
        for group in groups.prefix(8) {
            guard group.count > 1, let part = group[0] as? String, let words = group[1] as? [String] else { continue }
            var seen = Set<String>()
            let clean = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12)
            guard !clean.isEmpty else { continue }
            let label = target.hasPrefix("zh") ? (names[part] ?? part) : part
            output.append((label.isEmpty ? "" : label + " · ") + clean.joined(separator: "；"))
        }
        return output
    }
    static func withMeanings(_ translation: String, meanings: [String], target: String) -> String {
        guard !meanings.isEmpty else { return translation }
        let title = target.hasPrefix("zh") ? "常见释义" : "Word meanings"
        return translation + "\n\n" + title + "\n" + meanings.joined(separator: "\n")
    }

}
enum TranslationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// The visible UI is always native. A private web view is only a fallback transport.
final class TranslationService: NSObject, WKNavigationDelegate {
    var task: Task<Void, Never>?
    var web: WKWebView?
    var navigation: WKNavigation?
    var timer: Timer?
    var completion: ((Result<String, Error>) -> Void)?
    var token = UUID()
    var unitToken = UUID()
    var layout: TranslationLayout?
    var unitResults: [String] = []
    var targetLanguage = ""
    var sourceLanguage = "auto"
    var originalText = ""
    var wordMeanings: [String] = []
    var dictionaryAttempted = false
    var unitTranslatorForVerification: ((String, String, @escaping (Result<String, Error>) -> Void) -> Void)?
    var requestLoaderForVerification: ((URLRequest) async throws -> (Data, URLResponse))?
    var backendForVerification: String?
    var backend = "google"
    var polling = false
    func loadRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let loader = requestLoaderForVerification { return try await loader(request) }
        return try await URLSession.shared.data(for: request)
    }
    func cancel() {
        token = UUID()
        clearTransport()
        layout = nil; unitResults = []; wordMeanings = []; completion = nil
    }
    func clearTransport() {
        unitToken = UUID()
        ChromeBridge.shared.cancel()
        BackgroundBrowser.shared.cancelTranslation()
        task?.cancel(); task = nil
        timer?.invalidate(); timer = nil
        web?.stopLoading(); web?.navigationDelegate = nil; web = nil
        navigation = nil; polling = false
    }
    func translate(text: String, target: String, source: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        self.completion = completion
        layout = TranslationLayout(text)
        targetLanguage = target
        originalText = text
        dictionaryAttempted = false
        backend = backendForVerification ?? UserDefaults.standard.string(forKey: "translationBackend") ?? "google"
        sourceLanguage = source ?? (["browser", "chrome"].contains(backend)
            ? UserDefaults.standard.string(forKey: "chromeSourceLanguage") ?? "en" : "auto")
        if layout!.requests.isEmpty {
            let output = layout!.assemble([])
            cancel(); completion(.success(output)); return
        }
        translateRaw(text: layout!.requests[0], target: target)
    }
    func translateRaw(text: String, target: String) {
        let requestToken = unitToken
        if let translator = unitTranslatorForVerification {
            translator(text, target) { [weak self] result in
                guard let self, self.unitToken == requestToken else { return }
                self.finish(result)
            }
            return
        }
        if backend == "browser" {
            BackgroundBrowser.shared.translate(text: text, source: sourceLanguage, target: target) { [weak self] result in
                guard let self, self.unitToken == requestToken else { return }
                self.finish(result)
            }
            return
        }
        if backend == "chrome" {
            ChromeBridge.shared.translate(text: text, source: sourceLanguage, target: target) { [weak self] result in
                guard let self, self.unitToken == requestToken else { return }
                self.finish(result)
            }
            return
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let dictionary = TranslationRequest.isSingleWord(self.originalText)
                var request = URLRequest(url: TranslationRequest.publicURL(text: text, source: self.sourceLanguage, target: target, dictionary: dictionary))
                request.timeoutInterval = 6
                let (data, response) = try await self.loadRequest(request)
                guard self.unitToken == requestToken, !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw TranslationError.message("Google 连接暂不可用。")
                }
                let result = try TranslationRequest.parsePublicResponse(data)
                if dictionary {
                    self.dictionaryAttempted = true
                    self.wordMeanings = TranslationRequest.dictionaryMeanings(data, target: target)
                }
                self.finish(.success(result))
            } catch {
                guard self.unitToken == requestToken, !Task.isCancelled else { return }
                self.loadBackgroundPage(text: text, target: target, token: requestToken)
            }
        }
    }
    func loadBackgroundPage(text: String, target: String, token: UUID) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
        view.navigationDelegate = self
        web = view
        navigation = view.load(URLRequest(url: TranslationRequest.pageURL(text: text, target: target, source: sourceLanguage), timeoutInterval: 20))
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, self.unitToken == token else { return }
            ticks += 1
            if ticks >= 65 {
                self.finish(.failure(TranslationError.message("未能获取 Google 译文。请检查网络后重试；Google 可能正在限流或要求网页确认。")))
            } else if self.polling {
                self.pollPage(token: token)
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web, navigation === self.navigation else { return }
        polling = true
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === web, navigation === self.navigation else { return }; failedPage(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === web, navigation === self.navigation else { return }; failedPage(error)
    }
    func failedPage(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(TranslationError.message("无法连接 Google，请检查网络后重试。"))) }
    }
    func pollPage(token: UUID) {
        let script = """
        (() => {
          const segments = [...document.querySelectorAll('span.ryNqvb')].filter(el => el.getClientRects().length);
          if (!segments.length) return null;
          let root = segments[0];
          while (root.parentElement && !segments.every(el => root.contains(el))) root = root.parentElement;
          const walk = (node, inside = false) => {
            if (node.nodeType === 3) return inside || /^\\s*$/.test(node.textContent) ? node.textContent : '';
            if (node.nodeType !== 1) return '';
            if (node.tagName === 'BR') return '\\n';
            const selected = inside || segments.includes(node);
            if (!selected && !segments.some(el => node.contains(el))) return '';
            const text = [...node.childNodes].map(child => walk(child, selected)).join('');
            return /^(DIV|P|LI|SECTION|TR)$/.test(node.tagName) && text ? text + '\\n' : text;
          };
          return walk(root).trim() || null;
        })()
        """
        web?.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, self.unitToken == token, let text = result as? String, !text.isEmpty else { return }
            self.finish(.success(text))
        }
    }
    func finishDocument(_ output: String) {
        guard TranslationRequest.isSingleWord(originalText), !dictionaryAttempted, (unitTranslatorForVerification == nil || requestLoaderForVerification != nil) else {
            let result = TranslationRequest.withMeanings(output, meanings: wordMeanings, target: targetLanguage)
            let callback = completion
            cancel(); callback?(.success(result)); return
        }
        // Dictionary lookup is optional: failures never discard a successful translation.
        dictionaryAttempted = true
        let requestToken = token
        let target = targetLanguage
        let url = TranslationRequest.publicURL(text: originalText, source: sourceLanguage, target: target, dictionary: true)
        clearTransport()
        task = Task { @MainActor [weak self] in
            var meanings: [String] = []
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            if let (data, response) = try? await self?.loadRequest(request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                meanings = TranslationRequest.dictionaryMeanings(data, target: target)
            }
            guard let self, self.token == requestToken, !Task.isCancelled else { return }
            let result = TranslationRequest.withMeanings(output, meanings: meanings, target: target)
            let callback = self.completion
            self.cancel(); callback?(.success(result))
        }
    }
    func finish(_ result: Result<String, Error>) {
        if case .success(let text) = result, let layout {
            unitResults.append(text)
            if unitResults.count < layout.requests.count {
                clearTransport()
                translateRaw(text: layout.requests[unitResults.count], target: targetLanguage)
                return
            }
            let output = layout.assemble(unitResults)
            finishDocument(output); return
        }
        let callback = completion
        cancel()
        callback?(result)
    }
}
