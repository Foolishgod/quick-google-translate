import Foundation
import AppKit

func check(_ value: Bool, _ label: String) { guard value else { fatalError("FAIL: " + label) }; print("PASS: " + label) }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("QuickGoogleTranslate")
let profile = root.appendingPathComponent(".build/browser-fixture-profile")
let shim = root.appendingPathComponent(".build/browser-fixture")
let browser = BackgroundBrowser(profileOverride: profile, executableOverride: shim)
@MainActor func translate(_ text: String) async -> Result<String, Error> {
    await withCheckedContinuation { callback in
        browser.translate(text: text, source: "en", target: "zh-CN") { result in callback.resume(returning: result) }
    }
}
Task { @MainActor in
    do {
        let visible = BackgroundBrowser.arguments(profile: profile, headless: false)
        check(!visible.contains(where: { $0.hasPrefix("--remote-debugging") || $0.hasPrefix("--headless") }), "manual login has no automation connection")
        let hidden = BackgroundBrowser.arguments(profile: profile, headless: true)
        check(hidden.contains("--headless=new") && hidden.contains("--remote-debugging-address=127.0.0.1") && hidden.contains("--user-data-dir=" + profile.path), "headless browser uses a dedicated profile and loopback debugging")
        switch await translate("first") {
        case .success("你好"): print("PASS: cold browser startup does not cancel its own translation")
        case .failure(let error): throw error
        case .success(let text): throw TranslationError.message("Unexpected fixture result: \(text)")
        }
        if case .failure = await translate("classic") { print("PASS: classic results are never labelled advanced") } else { fatalError("classic accepted") }
        if case .success("你好") = await translate("switch") { print("PASS: reload after switching models before reading advanced output") } else { fatalError("model switch failed") }
        if case .failure = await translate("login") { print("PASS: require user action for login and verification") } else { fatalError("login error ignored") }
        var lateCallback = false
        browser.translate(text:"cancel",source:"en",target:"zh-CN") { _ in lateCallback=true }
        try await Task.sleep(nanoseconds:150_000_000)
        browser.cancelTranslation()
        try await Task.sleep(nanoseconds:500_000_000)
        check(!lateCallback,"ignore results after the floating window is dismissed")
        try await browser.launchLogin()
        check(browser.mode == .login && browser.process?.isRunning == true,"switch to an owned manual login browser")
        if case .failure = await translate("during login") { print("PASS: wait for manual login completion") } else { fatalError("login mode unexpectedly translated") }
        try await browser.startBackground()
        check(browser.mode == .background,"transition from manual login to a headless browser")
        try await browser.stop()
        check(browser.mode == .stopped && browser.process == nil,"stop only the owned browser process")
        print("All browser-controller fixture checks passed.")
        exit(0)
    } catch { browser.terminateOwnedProcess(); print("Fixture failed: \(error)"); exit(1) }
}
dispatchMain()
