import AppKit
import WebKit
import Security

struct TranslationRequest {
    static func normalize(_ raw: String) throws -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let value = lines.count > 1 ? lines.joined(separator: "\n") : normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TranslationError.message("请先选中一段文字。") }
        guard value.count <= 5000 else { throw TranslationError.message("文字太长，请选取 5,000 字以内的内容。") }
        return value
    }
    static func pageURL(text: String, target: String) -> URL {
        var c = URLComponents(string: "https://translate.google.com/")!
        c.queryItems = [URLQueryItem(name: "sl", value: "auto"), URLQueryItem(name: "tl", value: target), URLQueryItem(name: "text", value: text), URLQueryItem(name: "op", value: "translate")]
        return c.url!
    }
    static func parsePublicResponse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [[Any]] else { throw TranslationError.message("未能获取译文，请重试。") }
        let text = segments.compactMap { $0.first as? String }.joined()
        guard !text.isEmpty else { throw TranslationError.message("未能获取译文，请重试。") }
        return text
    }
    static func parseOfficialResponse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["data"] as? [String: Any],
              let translations = content["translations"] as? [[String: Any]],
              let value = translations.first?["translatedText"] as? String, !value.isEmpty else {
            throw TranslationError.message("Google Cloud 未返回译文，请检查连接设置。")
        }
        // Google encodes HTML entities even when format is text.
        return decodeEntities(value)
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
}
enum TranslationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct APIKeyStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.quickgoogletranslate.mac", kSecAttrAccount as String: "google-cloud-key"]
    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) -> Bool {
        if value.isEmpty { let status = SecItemDelete(query as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
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
    var unitTranslatorForVerification: ((String, String, @escaping (Result<String, Error>) -> Void) -> Void)?
    var polling = false
    func cancel() {
        token = UUID()
        clearTransport()
        layout = nil; unitResults = []; completion = nil
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
    func translate(text: String, target: String, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        self.completion = completion
        layout = TranslationLayout(text)
        targetLanguage = target
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
        if UserDefaults.standard.string(forKey: "translationBackend") == "browser" {
            BackgroundBrowser.shared.translate(text: text, source: UserDefaults.standard.string(forKey: "chromeSourceLanguage") ?? "en", target: target) { [weak self] result in
                guard let self, self.unitToken == requestToken else { return }
                self.finish(result)
            }
            return
        }
        if UserDefaults.standard.string(forKey: "translationBackend") == "chrome" {
            ChromeBridge.shared.translate(text: text, source: UserDefaults.standard.string(forKey: "chromeSourceLanguage") ?? "en", target: target) { [weak self] result in
                guard let self, self.unitToken == requestToken else { return }
                self.finish(result)
            }
            return
        }
        let key = APIKeyStore.read()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var request: URLRequest
                if let key, !key.isEmpty {
                    request = URLRequest(url: URL(string: "https://translation.googleapis.com/language/translate/v2")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["q": text, "target": target, "format": "text"])
                    request.timeoutInterval = 20
                } else {
                    var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
                    c.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"), URLQueryItem(name: "tl", value: target), URLQueryItem(name: "dt", value: "t"), URLQueryItem(name: "q", value: text)]
                    request = URLRequest(url: c.url!)
                    request.timeoutInterval = 4
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard self.unitToken == requestToken, !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw TranslationError.message(key == nil ? "Google 连接暂不可用。" : "Google Cloud 连接失败，请检查密钥、API 启用状态和配额。")
                }
                let result = try key == nil ? TranslationRequest.parsePublicResponse(data) : TranslationRequest.parseOfficialResponse(data)
                self.finish(.success(result))
            } catch {
                guard self.unitToken == requestToken, !Task.isCancelled else { return }
                if key == nil { self.loadBackgroundPage(text: text, target: target, token: requestToken) }
                else { self.finish(.failure(error)) }
            }
        }
    }
    func loadBackgroundPage(text: String, target: String, token: UUID) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
        view.navigationDelegate = self
        web = view
        navigation = view.load(URLRequest(url: TranslationRequest.pageURL(text: text, target: target), timeoutInterval: 20))
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
    func finish(_ result: Result<String, Error>) {
        if case .success(let text) = result, let layout {
            unitResults.append(text)
            if unitResults.count < layout.requests.count {
                clearTransport()
                translateRaw(text: layout.requests[unitResults.count], target: targetLanguage)
                return
            }
            let output = layout.assemble(unitResults)
            let callback = completion
            cancel(); callback?(.success(output)); return
        }
        let callback = completion
        cancel()
        callback?(result)
    }
}
