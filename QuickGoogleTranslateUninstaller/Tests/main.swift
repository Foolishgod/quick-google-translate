import AppKit
import Security

func check(_ value: Bool, _ label: String) { guard value else { fatalError("FAIL: " + label) }; print("PASS: " + label) }
if CommandLine.arguments.contains("--verify-process") {
    let values = OwnedBrowser.arguments(pid: getpid())
    check(values?.contains("--verify-process") == true, "read actual process arguments without logging private data")
    exit(0)
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("qgt-uninstaller-fixture-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let home = root.appendingPathComponent("Home")
let applications = root.appendingPathComponent("Applications")
let trash = root.appendingPathComponent("TestTrash")
try fm.createDirectory(at: applications, withIntermediateDirectories: true)
try fm.createDirectory(at: trash, withIntermediateDirectories: true)
let plan = UninstallPlan(home: home, applicationDirectories: [applications])
func createApp(_ name: String, identifier: String) throws -> URL {
    let app = applications.appendingPathComponent(name + ".app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":identifier], format: .xml, options: 0)
    try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
}
let own = try createApp("划词谷歌翻译", identifier: UninstallPlan.identifier)
let other = try createApp("Chrome", identifier: "com.google.Chrome")
let alias = applications.appendingPathComponent("Shortcut.app")
try fm.createSymbolicLink(at: alias, withDestinationURL: own)
try fm.createDirectory(at: plan.profile, withIntermediateDirectories: true)
try Data("fixture login only".utf8).write(to: plan.profile.appendingPathComponent("Cookies"))
let prefs = plan.knownFiles.first { $0.kind == .preferences }!.url!
try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("fixture preferences only".utf8).write(to: prefs)
let normalChrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
try fm.createDirectory(at: normalChrome, withIntermediateDirectories: true)
let cookie = normalChrome.appendingPathComponent("Cookies")
try Data("retain normal Chrome".utf8).write(to: cookie)
let found = plan.scan(extraApplications: [own, own], inspectKeychain: false, includeRunningApplications: false)
check(found.filter { $0.kind == .application }.count == 1, "deduplicate the application and reject another app and symlink aliases")
check(found.count == 3, "find only application, dedicated browser profile and preferences in fixtures")
check(!plan.permits(CleanupItem(kind: .support, title: "forged", detail: "", url: normalChrome)), "reject a substituted daily Chrome profile path")
let appItem = found.first { $0.kind == .application }!
let plist = own.appendingPathComponent("Contents/Info.plist")
try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"com.google.Chrome"],format:.xml,options:0).write(to:plist)
check(!plan.permits(appItem), "recheck application identity immediately before cleanup")
try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":UninstallPlan.identifier],format:.xml,options:0).write(to:plist)
let executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
check(OwnedBrowser.matches([executable,"--user-data-dir=" + plan.profile.path],profile:plan.profile), "identify only the app's dedicated Chrome profile")
check(!OwnedBrowser.matches([executable,"--user-data-dir=" + normalChrome.path],profile:plan.profile), "never stop daily Chrome")
check(!OwnedBrowser.matches([executable,"--user-data-dir=" + plan.profile.path + "-other"],profile:plan.profile), "require an exact browser profile argument")
check(!OwnedBrowser.matches([executable + " Helper","--user-data-dir=" + plan.profile.path],profile:plan.profile), "do not confuse another executable with the browser")
let lock = plan.profile.appendingPathComponent("SingletonLock")
try fm.createSymbolicLink(atPath:lock.path,withDestinationPath:"fixture-\(getpid())")
check(OwnedBrowser.hasActiveProfileLock(plan.profile), "block cleanup while the profile lock refers to a live process")
try fm.removeItem(at:lock)
try fm.createSymbolicLink(atPath:lock.path,withDestinationPath:"fixture-2147483647")
check(!OwnedBrowser.hasActiveProfileLock(plan.profile), "allow cleanup with a stale browser lock")
try fm.removeItem(at:lock)
var keyDeletes = 0
let results = plan.remove(found, syncPreferences:false, trash:{ url in try fm.moveItem(at:url,to:trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)) },deleteKey:{ keyDeletes += 1; return errSecSuccess })
check(results.count == 3 && results.allSatisfy { $0.hasPrefix("已移入") }, "move selected fixture data to a recoverable staging folder")
let remainingCookie = try Data(contentsOf:cookie)
check(fm.fileExists(atPath:other.path) && remainingCookie == Data("retain normal Chrome".utf8), "retain other apps and daily Chrome cookies during cleanup")
check(keyDeletes == 0, "do not delete an unselected keychain item")
let key = CleanupItem(kind:.keychain,title:"Google Cloud 密钥",detail:"",url:nil)
let keyResult = plan.remove([key],syncPreferences:false,trash:{_ in fatalError("keychain must not use file removal")},deleteKey:{keyDeletes += 1; return errSecSuccess})
check(keyDeletes == 1 && keyResult[0].hasPrefix("已删除"), "delete only the selected app-specific keychain item")
check(plan.keyQuery[kSecAttrService as String] as? String == UninstallPlan.identifier && plan.keyQuery[kSecAttrAccount as String] as? String == "google-cloud-key", "use the exact keychain service and account")
try fm.createDirectory(at: plan.support, withIntermediateDirectories: true)
let supportItem = plan.knownFiles.first { $0.kind == .support }!
let failure = plan.remove([supportItem],syncPreferences:false,trash:{_ in throw CocoaError(.fileWriteNoPermission)},deleteKey:{errSecSuccess})
check(failure[0].hasPrefix("未删除") && fm.fileExists(atPath:plan.support.path), "report permission failures and preserve the file")
let cache = plan.knownFiles.first { $0.kind == .cache }!
try fm.createDirectory(at: cache.url!.deletingLastPathComponent(), withIntermediateDirectories:true)
try fm.createSymbolicLink(at:cache.url!,withDestinationURL:normalChrome)
_ = plan.remove([cache],syncPreferences:false,trash:{url in try fm.moveItem(at:url,to:trash.appendingPathComponent("cache-link"))},deleteKey:{errSecSuccess})
check(fm.fileExists(atPath:cookie.path), "move a residue symlink without following it into daily Chrome")
print("All uninstaller fixture checks passed. No installed applications, real preferences or keychain items were removed.")
