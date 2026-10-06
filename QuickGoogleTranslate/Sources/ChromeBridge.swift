import Foundation
import Network
import Security

struct BridgeJob: Codable {
    let id: String
    let text: String
    let source: String
    let target: String
}
struct BridgeReply: Decodable {
    let id: String
    let text: String?
    let error: String?
    let model: String?
}

// The listener is bound to loopback only; each request requires a random pairing token.
final class ChromeBridge {
    static let shared = ChromeBridge()
    static let port: UInt16 = 48137
    let pairingCode: String
    let listenerPort: UInt16
    var listener: NWListener?
    var startupError: String?
    var lastSeen: Date?
    var pending: BridgeJob?
    var completion: ((Result<String, Error>) -> Void)?
    var timeout: Timer?
    var connected: Bool { lastSeen.map { Date().timeIntervalSince($0) < 10 } ?? false }
    init(pairingCode override: String? = nil, port: UInt16 = ChromeBridge.port) {
        listenerPort = port
        if let override { pairingCode = override; return }
        if let saved = UserDefaults.standard.string(forKey: "chromePairingCode"), saved.count == 64 {
            pairingCode = saved
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("Unable to generate pairing code") }
            pairingCode = bytes.map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(pairingCode, forKey: "chromePairingCode")
        }
    }
    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenerPort)!)
            let server = try NWListener(using: parameters)
            listener = server
            server.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.startupError = "Chrome 连接端口不可用，请退出其他翻译副本后重新启动。"
                    self?.complete(.failure(TranslationError.message(self?.startupError ?? "Chrome 连接失败。")))
                }
            }
            server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            server.start(queue: .main)
        } catch { startupError = "Chrome 连接未能启动，请重新打开应用。" }
    }
    func cancel() { pending = nil; completion = nil; timeout?.invalidate(); timeout = nil }
    func translate(text: String, source: String, target: String, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        if let startupError { completion(.failure(TranslationError.message(startupError))); return }
        guard connected else {
            completion(.failure(TranslationError.message("Chrome 扩展尚未连接。请在设置中打开连接说明，安装扩展并粘贴连接码，然后让 Google 翻译标签页保持打开。")))
            return
        }
        if source == target { completion(.failure(TranslationError.message("原文语言与目标语言相同，请在设置中修改语言。"))); return }
        pending = BridgeJob(id: UUID().uuidString, text: text, source: source, target: target)
        self.completion = completion
        timeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.complete(.failure(TranslationError.message("Chrome 高级翻译未及时返回。请查看 Google 翻译标签页，确认高级模式可用、网络正常后重试。")))
        }
    }
    func complete(_ result: Result<String, Error>) {
        let callback = completion
        cancel()
        callback?(result)
    }
    func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { connection.cancel() }
        receive(connection, buffer: Data())
    }
    func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, finished, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffer
            if let data { bytes.append(data) }
            guard bytes.count <= 65536 else { self.respond(connection, status: 413, object: ["error": "request too large"]); return }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if finished || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: bytes) }
                return
            }
            guard let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            let lines = header.components(separatedBy: "\r\n")
            let route = (lines.first ?? "").split(separator: " ")
            guard route.count == 3 else { self.respond(connection, status: 400, object: [:]); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased()
                guard headers[name] == nil else { self.respond(connection, status: 400, object: [:]); return }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let origin = headers["origin"]
            if let origin, !origin.hasPrefix("chrome-extension://") { self.respond(connection, status: 403, object: [:]); return }
            if route[0] == "OPTIONS" {
                self.respond(connection, status: 200, object: [:], origin: origin); return
            }
            guard headers["authorization"] == "Bearer " + self.pairingCode else { self.respond(connection, status: 401, object: ["error": "pairing required"], origin: origin); return }
            guard headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), (0...32768).contains(length) else {
                self.respond(connection, status: 400, object: [:], origin: origin); return
            }
            let bodyStart = boundary.upperBound
            let body = Data(bytes[bodyStart...])
            if body.count < length {
                if finished || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: bytes) }
                return
            }
            self.route(connection, method: String(route[0]), path: String(route[1]), body: Data(body.prefix(length)), origin: origin)
        }
    }
    func route(_ connection: NWConnection, method: String, path: String, body: Data, origin: String?) {
        if method == "GET", path == "/v1/status" || path == "/v1/job" {
            lastSeen = Date()
            if path == "/v1/job", let pending,
               let data = try? JSONEncoder().encode(pending), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                respond(connection, status: 200, object: ["job": object], origin: origin)
            } else { respond(connection, status: 200, object: ["job": NSNull(), "version": "1.3"], origin: origin) }
        } else if method == "POST", path == "/v1/result" {
            guard let reply = try? JSONDecoder().decode(BridgeReply.self, from: body) else { respond(connection, status: 400, object: [:], origin: origin); return }
            // Ignore responses for an already cancelled or superseded translation.
            guard reply.id == pending?.id else { respond(connection, status: 409, object: [:], origin: origin); return }
            respond(connection, status: 200, object: ["ok": true], origin: origin)
            if let error = reply.error { complete(.failure(TranslationError.message(error))) }
            else if reply.model == "advanced", let text = reply.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 12000 {
                complete(.success(text))
            } else { complete(.failure(TranslationError.message("网页没有确认高级模式，本次未采用经典模型。请在 Chrome 中检查语言与模型选项。"))) }
        } else { respond(connection, status: 404, object: [:], origin: origin) }
    }
    func respond(_ connection: NWConnection, status: Int, object: [String: Any], origin: String? = nil) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var header = "HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let origin { header += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\n" }
        var output = Data((header + "\r\n").utf8); output.append(body)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }
}
