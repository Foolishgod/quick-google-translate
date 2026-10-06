import AppKit
import Security
import LocalAuthentication
import Darwin

struct CleanupItem {
    enum Kind { case application, support, preferences, cache, webStorage, windowState, keychain }
    let kind: Kind
    let title: String
    let detail: String
    let url: URL?
}

struct UninstallPlan {
    static let identifier = "local.quickgoogletranslate.mac"
    let home: URL
    let applicationDirectories: [URL]
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applicationDirectories: [URL]? = nil) {
        self.home = home.standardizedFileURL
        self.applicationDirectories = applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }
    var support: URL { home.appendingPathComponent("Library/Application Support/QuickGoogleTranslate") }
    var profile: URL { support.appendingPathComponent("BrowserProfile") }
    var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.identifier, kSecAttrAccount as String: "google-cloud-key"]
    }
    func isApplication(_ url: URL) -> Bool {
        guard url.pathExtension == "app", !isSymlink(url),
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return plist["CFBundleIdentifier"] as? String == Self.identifier
    }
    func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
    var knownFiles: [CleanupItem] {
        [
            CleanupItem(kind: .support, title: "专用浏览器与旧版扩展资料", detail: "包含 Google 登录状态、网站记录和缓存；不影响日常 Chrome。", url: support),
            CleanupItem(kind: .preferences, title: "快捷键与翻译设置", detail: "删除语言、快捷键和连接设置。", url: home.appendingPathComponent("Library/Preferences/\(Self.identifier).plist")),
            CleanupItem(kind: .cache, title: "应用缓存", detail: "清理应用可能保存的网络缓存。", url: home.appendingPathComponent("Library/Caches/\(Self.identifier)")),
            CleanupItem(kind: .webStorage, title: "应用网络资料", detail: "清理系统为此应用保存的网络数据。", url: home.appendingPathComponent("Library/HTTPStorages/\(Self.identifier)")),
            CleanupItem(kind: .webStorage, title: "应用网络 Cookie", detail: "仅清理翻译应用的网络 Cookie。", url: home.appendingPathComponent("Library/HTTPStorages/\(Self.identifier).binarycookies")),
            CleanupItem(kind: .webStorage, title: "旧版应用 Cookie", detail: "清理系统可能保存的旧版网络 Cookie。", url: home.appendingPathComponent("Library/Cookies/\(Self.identifier).binarycookies")),
            CleanupItem(kind: .webStorage, title: "应用网页资料", detail: "清理系统可能保存的应用网页资料。", url: home.appendingPathComponent("Library/WebKit/\(Self.identifier)")),
            CleanupItem(kind: .windowState, title: "窗口状态", detail: "清理系统保存的窗口状态。", url: home.appendingPathComponent("Library/Saved Application State/\(Self.identifier).savedState"))
        ]
    }
    func scan(extraApplications: [URL] = [], inspectKeychain: Bool = true, includeRunningApplications: Bool = true) -> [CleanupItem] {
        var candidates = extraApplications
        for directory in applicationDirectories {
            candidates += (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        if includeRunningApplications { candidates += NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier).compactMap(\.bundleURL) }
        var seen = Set<String>()
        var found = candidates.map(\.standardizedFileURL).filter { isApplication($0) && seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }.map { CleanupItem(kind: .application, title: "划词谷歌翻译.app", detail: "应用本体", url: $0) }
        found += knownFiles.filter { item in item.url.map { FileManager.default.fileExists(atPath: $0.path) || isSymlink($0) } ?? false }
        if inspectKeychain {
            var query = keyQuery
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess || status == errSecInteractionNotAllowed {
                found.append(CleanupItem(kind: .keychain, title: "Google Cloud 密钥", detail: "仅删除此应用的 google-cloud-key；删除后无法从废纸篓恢复。", url: nil))
            }
        }
        return found
    }
    func permits(_ item: CleanupItem) -> Bool {
        if item.kind == .keychain { return item.url == nil }
        guard let url = item.url, url.isFileURL else { return false }
        if item.kind == .application { return isApplication(url.standardizedFileURL) }
        return knownFiles.contains { $0.kind == item.kind && $0.url?.standardizedFileURL.path == url.standardizedFileURL.path }
    }
    func remove(_ items: [CleanupItem], syncPreferences: Bool = true, trash: (URL) throws -> Void = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }, deleteKey: () -> OSStatus) -> [String] {
        var results: [String] = []
        for item in items {
            guard permits(item) else { results.append("未处理：\(item.title)（项目校验失败）"); continue }
            if item.kind == .keychain {
                let status = deleteKey()
                results.append(status == errSecSuccess || status == errSecItemNotFound ? "已删除：Google Cloud 密钥" : "未删除：Google Cloud 密钥（系统返回 \(status)）")
                continue
            }
            guard let url = item.url else { continue }
            guard FileManager.default.fileExists(atPath: url.path) || isSymlink(url) else { results.append("已不存在：\(item.title)"); continue }
            do {
                try trash(url)
                if item.kind == .preferences && syncPreferences {
                    // Clear cfprefsd's cached domain so the settings do not reappear.
                    if let keys = CFPreferencesCopyKeyList(Self.identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
                        for key in keys { CFPreferencesSetValue(key as CFString, nil, Self.identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
                        CFPreferencesSynchronize(Self.identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                    }
                    if FileManager.default.fileExists(atPath: url.path) { try trash(url) }
                }
                results.append("已移入废纸篓：\(item.title)\n\(url.path)")
            } catch { results.append("未删除：\(item.title)\n\(url.path)\n\(error.localizedDescription)") }
        }
        return results
    }
}

enum OwnedBrowser {
    static func hasActiveProfileLock(_ profile: URL) -> Bool {
        let lock = profile.appendingPathComponent("SingletonLock")
        guard let value = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path),
              let last = value.split(separator: "-").last, let pid = Int32(last), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4, length < 4_000_000 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 100_000 else { return nil }
        var offset = 4
        while offset < length && buffer[offset] != 0 { offset += 1 }
        while offset < length && buffer[offset] == 0 { offset += 1 }
        var values: [String] = []
        for _ in 0..<count {
            let start = offset
            while offset < length && buffer[offset] != 0 { offset += 1 }
            guard offset < length else { return nil }
            values.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            offset += 1
        }
        return values
    }
    static func matches(_ arguments: [String], profile: URL) -> Bool {
        guard let first = arguments.first, URL(fileURLWithPath: first).lastPathComponent == "Google Chrome" else { return false }
        return arguments.contains("--user-data-dir=" + profile.path)
    }
    static func running(profile: URL) throws -> [pid_t] {
        let listing = Process()
        let pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-ax", "-o", "pid="]
        listing.standardOutput = pipe; listing.standardError = FileHandle.nullDevice
        try listing.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
        guard listing.terminationStatus == 0 else { throw NSError(domain: "Uninstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法检查专用浏览器。请先退出翻译应用和专用登录窗口后重试。"] ) }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            .filter { pid in arguments(pid: pid).map { matches($0, profile: profile) } ?? false }
    }
    @MainActor static func stopTranslation(profile: URL) async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: UninstallPlan.identifier)
        for application in applications { application.terminate() }
        for _ in 0..<100 {
            if applications.allSatisfy(\.isTerminated) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard applications.allSatisfy(\.isTerminated) else { throw NSError(domain: "Uninstaller", code: 2, userInfo: [NSLocalizedDescriptionKey: "翻译应用尚未退出。请从它的菜单栏退出后重试。"] ) }
        for pid in try running(profile: profile) {
            if let argv = arguments(pid: pid), matches(argv, profile: profile) { _ = kill(pid, SIGTERM) }
        }
        for _ in 0..<100 {
            if try running(profile: profile).isEmpty, !hasActiveProfileLock(profile) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "Uninstaller", code: 3, userInfo: [NSLocalizedDescriptionKey: "专用浏览器尚未退出。请关闭专用登录窗口后重试。"] )
    }
}
