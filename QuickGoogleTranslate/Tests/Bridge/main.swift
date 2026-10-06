import Foundation
import Network

let bridge = ChromeBridge(pairingCode: String(repeating: "a", count: 64), port: 48138)
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
@MainActor func send(_ path: String, method: String = "GET", body: [String: Any]? = nil, authorize: Bool = true, origin: String? = nil) async throws -> (Int, [String: Any]) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:48138" + path)!)
    request.httpMethod = method
    request.timeoutInterval = 3
    if authorize { request.setValue("Bearer " + bridge.pairingCode, forHTTPHeaderField: "Authorization") }
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    return ((response as! HTTPURLResponse).statusCode, (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
}
Task { @MainActor in
    do {
    bridge.start()
    try await Task.sleep(nanoseconds: 250_000_000)
    let unauth = try await send("/v1/job", authorize: false)
    check(unauth.0 == 401 && unauth.1["job"] == nil, "require pairing before revealing jobs")
    check(try await send("/v1/status", origin: "https://example.com").0 == 403, "reject ordinary website origins")
    check(try await send("/v1/status", origin: "chrome-extension://fixture").0 == 200 && bridge.connected, "allow paired extension and refresh connection status")
    var returned: Result<String, Error>?
    bridge.translate(text: "Hello fixture", source: "en", target: "zh-CN") { returned = $0 }
    let job = try await send("/v1/job").1["job"] as! [String: Any]
    let id = job["id"] as! String
    check(job["text"] as? String == "Hello fixture" && job["source"] as? String == "en", "deliver the requested source and target")
    check(try await send("/v1/result", method: "POST", body: ["id":"stale", "text":"旧结果", "model":"advanced"]).0 == 409 && returned == nil, "ignore stale replies")
    _ = try await send("/v1/result", method: "POST", body: ["id":id, "text":"经典结果", "model":"classic"])
    if case .failure? = returned { print("PASS: reject classic model results") } else { fatalError("classic model was accepted") }
    returned = nil
    bridge.translate(text: "Hello again", source: "en", target: "zh-CN") { returned = $0 }
    let next = bridge.pending!.id
    _ = try await send("/v1/result", method: "POST", body: ["id":next, "text":"你好", "model":"advanced"])
    if case .success("你好")? = returned { print("PASS: return confirmed advanced result") } else { fatalError("advanced result not delivered") }
    returned = nil
    bridge.translate(text: "Cancelled", source: "en", target: "zh-CN") { returned = $0 }
    let cancelled = bridge.pending!.id
    bridge.cancel()
    check(try await send("/v1/result", method: "POST", body: ["id":cancelled, "text":"late", "model":"advanced"]).0 == 409 && returned == nil, "ignore replies after the floating window is dismissed")
    bridge.translate(text: "Wrong pair", source: "en", target: "en") { returned = $0 }
    if case .failure? = returned { print("PASS: reject identical source and target") } else { fatalError("identical languages accepted") }
    bridge.listener?.cancel()
    print("All local bridge checks passed.")
    exit(0)
    } catch { print("Bridge check failed: \(error)"); exit(1) }
}
dispatchMain()
