import AppKit
import Sparkle

final class AppMaintenance: NSObject, SPUUpdaterDelegate {
    var controller: SPUStandardUpdaterController!
    var started = false
    var probeFeed: String?
    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }
    func start() throws {
        if !started { try controller.updater.start(); started = true }
    }
    func checkForUpdates() throws { try start(); controller.checkForUpdates(nil) }
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { BackgroundBrowser.shared.terminateOwnedProcess() }
    func feedURLString(for updater: SPUUpdater) -> String? { probeFeed }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if probeFeed != nil {
            print("PASS: Sparkle fetched and verified the signed feed; found version \(item.versionString), selected archive=\(item.fileURL?.lastPathComponent ?? "none")")
            if CommandLine.arguments.contains("--expect-delta") { precondition(item.fileURL?.pathExtension == "delta", "Sparkle must select the delta for the test base") }
            NSApp.terminate(nil)
        }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if probeFeed != nil { print("FAIL: update feed: \(error.localizedDescription)"); exit(1) }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if probeFeed != nil { print("FAIL: test feed should offer a newer version"); exit(1) }
    }
    func openUninstaller() throws {
        guard !controller.updater.sessionInProgress else { throw TranslationError.message("请先完成或取消当前更新，再打开卸载工具。") }
        let fm = FileManager.default
        guard let resources = Bundle.main.resourceURL else { throw TranslationError.message("找不到内置卸载工具。") }
        let source = resources.appendingPathComponent("Uninstaller.app")
        guard fm.fileExists(atPath: source.path) else { throw TranslationError.message("找不到内置卸载工具，请重新安装完整版本。") }
        // Run outside the translating app so removal cannot delete the running helper.
        let temporary = fm.temporaryDirectory.appendingPathComponent("qgt-uninstall-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let destination = temporary.appendingPathComponent("Uninstaller.app")
        do { try fm.copyItem(at: source, to: destination) }
        catch { try? fm.removeItem(at: temporary); throw error }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--target-app", Bundle.main.bundleURL.path, "--temporary-copy"]
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            if let error {
                try? fm.removeItem(at: temporary)
                DispatchQueue.main.async {
                    let alert = NSAlert(); alert.messageText = "卸载工具未能打开"; alert.informativeText = error.localizedDescription; alert.runModal()
                }
            }
        }
    }
    func verifySetup() {
        let info = Bundle.main.infoDictionary!
        precondition(Data(base64Encoded: info["SUPublicEDKey"] as! String)?.count == 32)
        precondition((info["SUFeedURL"] as! String).hasPrefix("https://"))
        precondition(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true && info["SURequireSignedFeed"] as? Bool == true)
        let helper = Bundle.main.resourceURL!.appendingPathComponent("Uninstaller.app")
        precondition(Bundle(url: helper)?.bundleIdentifier == "local.quickgoogletranslate.uninstaller")
        print("PASS: signed update feed, archive verification, linked Sparkle and bundled uninstaller")
    }
}
