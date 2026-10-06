import Foundation
import AppKit

func check(_ value: Bool, _ label: String) { guard value else { fatalError("FAIL: " + label) }; print("PASS: " + label) }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("QuickGoogleTranslate")
let profile = root.appendingPathComponent(".build/browser-fixture-profile")
let shim = root.appendingPathComponent(".build/browser-fixture")
let browser = BackgroundBrowser(profileOverride: profile, executableOverride: shim)
@MainActor func translate(_ text: String, target: String = "zh-CN") async -> Result<String, Error> {
    await withCheckedContinuation { callback in browser.translate(text: text, source: "en", target: target) { callback.resume(returning: $0) } }
}
func trace(_ name: String) -> Int { let data = try! Data(contentsOf: profile.appendingPathComponent("fixture-trace.json")); return (try! JSONSerialization.jsonObject(with: data) as! [String: Any])[name] as! Int }
Task { @MainActor in
    do {
        let visible = BackgroundBrowser.arguments(profile: profile, headless: false)
        check(!visible.contains(where: { $0.hasPrefix("--remote-debugging") || $0.hasPrefix("--headless") }), "manual login has no automation connection")
        let hidden = BackgroundBrowser.arguments(profile: profile, headless: true)
        check(hidden.contains("--headless=new") && hidden.contains("--remote-debugging-address=127.0.0.1") && hidden.contains("--user-data-dir=" + profile.path), "dedicated profile and loopback debugging")
        if case .success("结果:first") = await translate("first") {} else { fatalError("cold startup failed") }
        check(trace("created") == 1 && trace("navigated") == 1, "cold request creates and loads one empty page")
        for text in ["second", "third", "third"] { if case .success(let result) = await translate(text) { check(result == "结果:"+text,"new input returned: "+text) } else { fatalError("reuse failed") } }
        check(trace("created") == 1 && trace("navigated") == 1 && trace("reloaded") == 0 && trace("closed") == 0, "three warm requests reuse the page without loading, reloading or closing")
        if case .failure = await translate("classic") {} else { fatalError("classic accepted") }
        if case .failure = await translate("login") {} else { fatalError("login error ignored") }
        check(trace("navigated") == 1, "model/login errors do not silently reload or accept classic output")
        if case .success = await translate("language",target:"ja") {} else { fatalError("language switch failed") }
        check(trace("created") == 1 && trace("navigated") == 2,"language changes reload once while retaining the same page")
        if case .success = await translate("recover",target:"ja") {} else { fatalError("page recovery failed") }
        check(trace("created") == 2 && trace("navigated") == 3 && trace("closed") == 1,"invalid page recovers once, then returns fresh output")
        if case .success = await translate("disconnect",target:"ja") {} else { fatalError("target recovery failed") }
        check(trace("created") == 3 && trace("navigated") == 4,"lost target recreates one page")
        var lateCallback = false
        browser.translate(text:"old",source:"en",target:"ja") { _ in lateCallback=true }
        try await Task.sleep(nanoseconds:100_000_000)
        let start=Date()
        if case .success("结果:new") = await translate("new",target:"ja") {} else { fatalError("superseded request failed") }
        check(Date().timeIntervalSince(start)<1,"new input does not wait for the old page result")
        try await Task.sleep(nanoseconds:1_300_000_000)
        check(!lateCallback,"superseded output cannot replace the latest result")
        browser.translate(text:"cancel",source:"en",target:"ja") { _ in lateCallback=true }
        try await Task.sleep(nanoseconds:100_000_000)
        browser.cancelTranslation()
        try await Task.sleep(nanoseconds:1_300_000_000)
        check(!lateCallback && browser.pageSessionID != nil,"closing the float cancels results and keeps the page warm")
        check(trace("navigated") == 4 && trace("created") == 3,"rapid switching and dismissal do not reload")
        try await browser.launchLogin()
        check(browser.pageSessionID == nil && browser.mode == .login && browser.process?.isRunning == true,"manual login clears the reusable page")
        if case .failure = await translate("during login") {} else { fatalError("login mode unexpectedly translated") }
        try await browser.startBackground()
        if case .success = await translate("after login") {} else { fatalError("after login failed") }
        check(trace("created") == 1 && trace("navigated") == 1,"returning from login starts one fresh page")
        try await browser.stop()
        check(browser.mode == .stopped && browser.process == nil && browser.pageSessionID == nil,"stop clears the owned browser and retained page")
        print("All reusable browser controller checks passed.");exit(0)
    } catch { browser.terminateOwnedProcess(); print("Fixture failed: \(error)");exit(1) }
}
dispatchMain()
