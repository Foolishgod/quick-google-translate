import AppKit
import Foundation

final class CDPClient {
    let session = URLSession(configuration: .ephemeral)
    var socket: URLSessionWebSocketTask?
    var receiver: Task<Void, Never>?
    var counter = 0
    var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    func connect(_ url: URL) {
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        receiver = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: continue }
                    guard let self, let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = response["id"] as? Int, let callback = self.pending.removeValue(forKey: id) else { continue }
                    if response["error"] != nil { callback.resume(throwing: TranslationError.message("后台浏览器操作失败，请重新启动后台浏览器。")) }
                    else { callback.resume(returning: response["result"] as? [String: Any] ?? [:]) }
                }
            } catch { self?.close() }
        }
    }
    @MainActor func call(_ method: String, params: [String: Any] = [:], sessionID: String? = nil, timeout: TimeInterval = 12) async throws -> [String: Any] {
        guard let socket else { throw TranslationError.message("后台浏览器未连接。") }
        counter += 1
        let id = counter
        var request: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionID { request["sessionId"] = sessionID }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8) else { throw TranslationError.message("后台浏览器请求无效。") }
        return try await withCheckedThrowingContinuation { callback in
            pending[id] = callback
            Task { @MainActor [weak self] in
                do { try await socket.send(.string(text)) }
                catch { self?.pending.removeValue(forKey: id)?.resume(throwing: TranslationError.message("后台浏览器连接已断开，请重新启动。")) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: TranslationError.message("后台浏览器未及时返回结果，请检查 Google 页面后重试。"))
            }
        }
    }
    func close() {
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        let callbacks = Array(pending.values)
        pending.removeAll()
        for callback in callbacks { callback.resume(throwing: TranslationError.message("后台浏览器连接已关闭。")) }
    }
}

final class BackgroundBrowser {
    static let shared = BackgroundBrowser()
    enum Mode { case stopped, login, background }
    var mode: Mode = .stopped
    let profileOverride: URL?
    let executableOverride: URL?
    init(profileOverride: URL? = nil, executableOverride: URL? = nil) {
        self.profileOverride = profileOverride
        self.executableOverride = executableOverride
    }
    var process: Process?
    var client: CDPClient?
    var request: Task<Void, Never>?
    var requestID = UUID()
    var targetID: String?
    var statusText: String {
        guard process?.isRunning == true else { return "浏览器尚未运行" }
        return mode == .login ? "登录窗口已打开 · 完成后转入后台" : "浏览器已在后台运行"
    }
    var profileURL: URL {
        if let profileOverride { return profileOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("QuickGoogleTranslate/BrowserProfile", isDirectory: true)
    }
    var executableURL: URL? {
        if let executableOverride { return executableOverride }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let url = app.appendingPathComponent("Contents/MacOS/Google Chrome")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    static func arguments(profile: URL, headless: Bool) -> [String] {
        var values = ["--user-data-dir=" + profile.path, "--no-first-run", "--no-default-browser-check"]
        if headless { values += ["--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1", "about:blank"] }
        else { values += ["https://translate.google.com/?sl=en&tl=zh-CN&op=translate"] }
        return values
    }
    @MainActor func stop(cancelRequest: Bool = true) async throws {
        if cancelRequest { cancelTranslation() }
        client?.close(); client = nil
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<100 {
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !process.isRunning else { throw TranslationError.message("请关闭专用登录浏览器的所有窗口后再转入后台。") }
        }
        process = nil; mode = .stopped
    }
    @MainActor func launchLogin() async throws {
        try await stop()
        try launch(headless: false)
    }
    @MainActor func startBackground() async throws {
        if mode == .background, process?.isRunning == true, client?.socket != nil { return }
        try await stop(cancelRequest: false)
        try launch(headless: true)
        let portFile = profileURL.appendingPathComponent("DevToolsActivePort")
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard process?.isRunning == true else { throw TranslationError.message("后台浏览器没有启动。请先关闭专用登录窗口，再重试。") }
            if let text = try? String(contentsOf: portFile, encoding: .utf8) {
                let lines = text.split(whereSeparator: \.isNewline)
                if lines.count >= 2, let port = UInt16(lines[0]), port > 0, lines[1].hasPrefix("/devtools/browser/"), let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") {
                    let connection = CDPClient()
                    connection.connect(url)
                    client = connection
                    _ = try await connection.call("Browser.getVersion")
                    return
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TranslationError.message("无法连接后台浏览器，请重新启动后重试。")
    }
    func launch(headless: Bool) throws {
        guard let executableURL else { throw TranslationError.message("需要安装 Google Chrome 作为浏览器引擎。无需扩展，也不需要使用你的日常浏览器窗口。") }
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        if headless {
            let portFile = profileURL.appendingPathComponent("DevToolsActivePort")
            if FileManager.default.fileExists(atPath: portFile.path) { try FileManager.default.removeItem(at: portFile) }
        }
        let child = Process()
        child.executableURL = executableURL
        child.arguments = Self.arguments(profile: profileURL, headless: headless)
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; mode = headless ? .background : .login
    }
    func cancelTranslation() {
        requestID = UUID()
        request?.cancel(); request = nil
        if let targetID, let client {
            Task { @MainActor in _ = try? await client.call("Target.closeTarget", params: ["targetId": targetID], timeout: 3) }
        }
        targetID = nil
    }
    func translate(text: String, source: String, target: String, completion: @escaping (Result<String, Error>) -> Void) {
        cancelTranslation()
        let token = requestID
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if source == target { throw TranslationError.message("原文语言和目标语言相同，请修改设置。") }
                if self.mode == .login, self.process?.isRunning == true { throw TranslationError.message("请先完成专用窗口中的登录，再在设置中点击“转入后台”。") }
                try await self.startBackground()
                // startBackground may stop an older browser; restore this request's token.
                guard !Task.isCancelled else { return }
                self.requestID = token
                guard let client = self.client else { throw TranslationError.message("后台浏览器未连接。") }
                let result = try await client.call("Target.createTarget", params: ["url": "about:blank"])
                guard let targetID = result["targetId"] as? String else { throw TranslationError.message("无法创建后台翻译页面。") }
                guard self.requestID == token, !Task.isCancelled else {
                    _ = try? await client.call("Target.closeTarget", params: ["targetId": targetID], timeout: 3)
                    return
                }
                self.targetID = targetID
                let attached = try await client.call("Target.attachToTarget", params: ["targetId": targetID, "flatten": true])
                try Task.checkCancellation()
                guard let sessionID = attached["sessionId"] as? String else { throw TranslationError.message("无法连接后台翻译页面。") }
                var components = URLComponents(url: TranslationRequest.pageURL(text: text, target: target), resolvingAgainstBaseURL: false)!
                components.queryItems = components.queryItems!.map { $0.name == "sl" ? URLQueryItem(name: "sl", value: source) : $0 }
                let initialLoader = try await self.loaderID(client, sessionID: sessionID)
                _ = try await client.call("Page.navigate", params: ["url": components.url!.absoluteString], sessionID: sessionID)
                try await self.waitForNavigation(client, sessionID: sessionID, previous: initialLoader)
                let scriptURL = Bundle.main.resourceURL!.appendingPathComponent("BrowserTranslate.js")
                let script = try String(contentsOf: scriptURL, encoding: .utf8)
                var value: [String: Any]?
                for attempt in 0..<2 {
                    let evaluated = try await client.call("Runtime.evaluate", params: ["expression": script, "awaitPromise": true, "returnByValue": true], sessionID: sessionID, timeout: 55)
                    guard self.requestID == token, !Task.isCancelled else { return }
                    let remote = evaluated["result"] as? [String: Any]
                    value = remote?["value"] as? [String: Any]
                    if value?["reload"] as? Bool == true {
                        guard attempt == 0 else { throw TranslationError.message("高级模型选项没有保留，请打开登录窗口手动选择高级后重试。") }
                        let previous = try await self.loaderID(client, sessionID: sessionID)
                        _ = try await client.call("Page.reload", sessionID: sessionID)
                        try await self.waitForNavigation(client, sessionID: sessionID, previous: previous)
                    } else { break }
                }
                if let message = value?["error"] as? String { throw TranslationError.message(message) }
                guard value?["model"] as? String == "advanced", let translation = value?["text"] as? String, !translation.isEmpty else { throw TranslationError.message("网页未确认高级译文，请打开登录窗口检查 Google 翻译页面。") }
                completion(.success(translation))
            } catch {
                if self.requestID == token, !Task.isCancelled { completion(.failure(error)) }
            }
            if self.requestID == token { self.cancelTranslation() }
        }
    }
    @MainActor func loaderID(_ client: CDPClient, sessionID: String) async throws -> String {
        let tree = try await client.call("Page.getFrameTree", sessionID: sessionID)
        return ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["loaderId"] as? String ?? ""
    }
    @MainActor func waitForNavigation(_ client: CDPClient, sessionID: String, previous: String) async throws {
        for _ in 0..<150 {
            try Task.checkCancellation()
            if let current = try? await loaderID(client, sessionID: sessionID), !current.isEmpty, current != previous {
                if let result = try? await client.call("Runtime.evaluate", params: ["expression": "document.readyState", "returnByValue": true], sessionID: sessionID),
                   (result["result"] as? [String: Any])?["value"] as? String == "complete" { return }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TranslationError.message("Google 页面加载较慢，请检查网络后重试。")
    }
    func terminateOwnedProcess() {
        cancelTranslation()
        client?.close()
        if process?.isRunning == true { process?.terminate() }
    }
}
