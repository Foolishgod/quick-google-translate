import AppKit
import Security

final class ItemList: NSStackView { override var isFlipped: Bool { true } }

final class Uninstaller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let plan = UninstallPlan()
    var window: NSWindow!
    var list: NSStackView!
    var status: NSTextField!
    var removeButton: NSButton!
    var refreshButton: NSButton!
    var chooseButton: NSButton!
    var spinner: NSProgressIndicator!
    var rows: [(CleanupItem, NSButton)] = []
    var extraApplications: [URL] = []
    var working = false
    let preview = CommandLine.arguments.contains("--preview")
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--target-app"), CommandLine.arguments.count > index + 1 {
            let target = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            if plan.isApplication(target) { extraApplications.append(target) }
        }
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let root = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出卸载工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = applicationMenu; menu.addItem(root); NSApp.mainMenu = menu
        buildWindow()
        if preview {
            let samples = [CleanupItem(kind: .application, title: "划词谷歌翻译.app", detail: "应用本体", url: URL(fileURLWithPath: "/Applications/划词谷歌翻译.app")),
                           CleanupItem(kind: .support, title: "专用浏览器与旧版扩展资料", detail: "包含 Google 登录状态、网站记录和缓存；不影响日常 Chrome。", url: plan.support),
                           CleanupItem(kind: .preferences, title: "快捷键与翻译设置", detail: "删除语言、快捷键和连接设置。", url: plan.knownFiles[1].url)]
            render(samples)
            chooseButton.isEnabled = false; refreshButton.isEnabled = false; removeButton.isEnabled = false
            if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let view = self.window.contentView!
                    view.layoutSubtreeIfNeeded()
                    self.window.displayIfNeeded()
                    precondition(!view.hasAmbiguousLayout, "Unambiguous root layout")
                    precondition(self.rows.count == 3 && !self.removeButton.isEnabled, "Preview must never uninstall")
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                    print("PASS: native uninstaller layout and read-only preview")
                    for child in view.subviews { print("\(type(of: child)): \(child.frame), ambiguous=\(child.hasAmbiguousLayout)") }
                    NSApp.terminate(nil)
                }
            }
        } else { refresh() }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !working }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { working ? .terminateCancel : .terminateNow }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }
    func applicationWillTerminate(_ notification: Notification) {
        guard CommandLine.arguments.contains("--temporary-copy") else { return }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        guard parent.deletingLastPathComponent().resolvingSymlinksInPath() == temporary.resolvingSymlinksInPath(), parent.lastPathComponent.hasPrefix("qgt-uninstall-") else { return }
        try? FileManager.default.removeItem(at: parent)
    }
    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "划词谷歌翻译 · 卸载工具"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = window.contentView!
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let title = label("卸载划词谷歌翻译", size: 25, weight: .semibold)
        let intro = label("勾选需要移除的项目。文件会移入废纸篓，日常 Chrome 的资料会保留。", color: .secondaryLabelColor)
        let header = NSStackView(views: [title, intro]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 8
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.borderType = .noBorder
        list = ItemList(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 12
        list.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = list
        NSLayoutConstraint.activate([list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        status = label("正在查找…", color: .secondaryLabelColor)
        spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let progress = NSStackView(views: [spinner, status]); progress.spacing = 8
        let note = label("辅助功能权限需要手动移除。若装过 1.3 配套 Chrome 扩展，也请在 Chrome 中移除。", size: 12, color: .secondaryLabelColor)
        let permission = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openPermission))
        permission.bezelStyle = .inline
        chooseButton = NSButton(title: "选择应用…", target: self, action: #selector(chooseApplication))
        refreshButton = NSButton(title: "重新扫描", target: self, action: #selector(refresh))
        removeButton = NSButton(title: "卸载所选项目…", target: self, action: #selector(uninstall))
        removeButton.bezelStyle = .rounded; removeButton.hasDestructiveAction = true
        let spacer = NSView()
        let actions = NSStackView(views: [chooseButton, refreshButton, spacer, removeButton]); actions.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [progress, note, permission, actions]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 10
        for view in [header, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor), scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -18),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            actions.widthAnchor.constraint(equalTo: footer.widthAnchor), note.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])
    }
    func clearList() { for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }; rows = [] }
    func render(_ items: [CleanupItem]) {
        clearList()
        for item in items {
            let checkbox = NSButton(checkboxWithTitle: item.title, target: self, action: #selector(selectionChanged))
            checkbox.font = .systemFont(ofSize: 14, weight: .medium); checkbox.state = .on
            let description = label(item.detail, size: 12, color: .secondaryLabelColor)
            let text = NSStackView(views: [checkbox, description]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 6
            if let url = item.url { let path = label(url.path, size: 11, color: .tertiaryLabelColor); path.isSelectable = true; text.addArrangedSubview(path) }
            let card = NSView(); card.wantsLayer = true; card.layer?.cornerRadius = 12; card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            text.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(text)
            list.addArrangedSubview(card)
            NSLayoutConstraint.activate([card.widthAnchor.constraint(equalTo: list.widthAnchor), text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14), text.topAnchor.constraint(equalTo: card.topAnchor, constant: 12), text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)])
            for field in text.arrangedSubviews.compactMap({ $0 as? NSTextField }) { field.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
            rows.append((item, checkbox))
        }
        if items.isEmpty { addMessage("没有找到可清理的项目", detail: "如果应用在下载文件夹或其他位置，点击“选择应用…”添加它。") }
        selectionChanged()
    }
    func addMessage(_ title: String, detail: String) {
        let stack = NSStackView(views: [label(title, size: 16, weight: .medium), label(detail, color: .secondaryLabelColor)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        list.addArrangedSubview(stack); stack.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        for field in stack.arrangedSubviews { field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    @objc func selectionChanged() {
        let count = rows.filter { $0.1.state == .on }.count
        status.stringValue = rows.isEmpty ? "扫描完成" : "找到 \(rows.count) 个项目，已选择 \(count) 个"
        removeButton.isEnabled = count > 0 && !working && !preview
    }
    @objc func refresh() { guard !working, !preview else { return }; render(plan.scan(extraApplications: extraApplications)) }
    @objc func chooseApplication() {
        guard !working, !preview else { return }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = false; chooser.canChooseFiles = true; chooser.allowedContentTypes = [.applicationBundle]
        chooser.prompt = "添加"; chooser.message = "请选择划词谷歌翻译.app，仅接受此应用的身份标识。"
        chooser.beginSheetModal(for: window) { response in
            guard response == .OK, let url = chooser.url else { return }
            guard self.plan.isApplication(url) else { self.showError("无法添加", "请选择“划词谷歌翻译”应用本体。此工具不会卸载其他软件。"); return }
            self.extraApplications.append(url); self.refresh()
        }
    }
    func setWorking(_ value: Bool) {
        working = value; refreshButton.isEnabled = !value; chooseButton.isEnabled = !value
        for (_, button) in rows { button.isEnabled = !value }
        removeButton.isEnabled = !value && rows.contains { $0.1.state == .on }
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    @objc func uninstall() {
        guard !working, !preview else { return }
        let selected = rows.filter { $0.1.state == .on }.map(\.0)
        guard !selected.isEmpty else { return }
        let confirmation = NSAlert(); confirmation.alertStyle = .warning
        confirmation.messageText = "卸载所选的 \(selected.count) 个项目？"
        confirmation.informativeText = "将先退出翻译应用及它的专用浏览器，再把所选文件移入废纸篓。\n\n" + selected.map(\.title).joined(separator: "\n") + (selected.contains { $0.kind == .keychain } ? "\n\nGoogle Cloud 密钥将永久删除，无法从废纸篓恢复。" : "")
        confirmation.addButton(withTitle: "卸载"); confirmation.addButton(withTitle: "取消")
        confirmation.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.setWorking(true); self.status.stringValue = "正在退出翻译应用和专用浏览器…"
            Task { @MainActor in
                do {
                    try await OwnedBrowser.stopTranslation(profile: self.plan.profile)
                    self.status.stringValue = "正在清理所选项目…"
                    let results = self.plan.remove(selected, deleteKey: { SecItemDelete(self.plan.keyQuery as CFDictionary) })
                    self.clearList()
                    let failed = results.contains { $0.hasPrefix("未") }
                    self.addMessage(failed ? "部分项目需要处理" : "所选项目已清理", detail: results.joined(separator: "\n\n"))
                    self.setWorking(false); self.removeButton.isEnabled = false
                    self.status.stringValue = "文件已移入废纸篓；辅助功能条目请在系统设置中手动移除。"
                } catch {
                    self.setWorking(false); self.selectionChanged(); self.showError("暂未卸载", error.localizedDescription)
                }
            }
        }
    }
    func showError(_ title: String, _ message: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.beginSheetModal(for: window) }
    @objc func openPermission() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
}

let app = NSApplication.shared
let delegate = Uninstaller()
app.delegate = delegate
app.run()
