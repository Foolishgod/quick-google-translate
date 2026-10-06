import AppKit
import Carbon
import ApplicationServices

final class TranslationPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

final class GlassCard: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.22).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 0.5
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let hotKey = HotKey()
    var statusItem: NSStatusItem!
    var panel: TranslationPanel!
    let translationService = TranslationService()
    var sourceView: NSTextView!
    var resultView: NSTextView!
    var copyButton: NSButton!
    var retryButton: NSButton!
    var spinner: NSProgressIndicator!
    var sourceText = ""
    var translatedText = ""
    var message: NSTextField!
    var languageLabel: NSTextField!
    var pinButton: NSButton!
    var isPinned = false
    var panelPresented = false
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var activationObserver: NSObjectProtocol?
    var sourceFormatting: NSAttributedString?
    var settings: NSWindow?
    var permissionLabel: NSTextField?
    var permissionTimer: Timer?
    var chromeWindow: NSWindow?
    var chromeStatus: NSTextField?
    var browserWindow: NSWindow?
    var browserStatus: NSTextField?
    var maintenance: AppMaintenance?
    var maintenanceWindow: NSWindow?
    var recorder: Recorder?
    var shortcutStatus: NSTextField?
    var shortcut = Shortcut.saved
    var busy = false
    var selectionRevision = 0
    var readSelectionAgain = false
    // Controlled adapters are used only by the read-only native verification modes.
    var selectionReaderForVerification: ((@escaping (String?) -> Void) -> Void)?
    var translatorForVerification: ((String, String, @escaping (Result<String, Error>) -> Void) -> Void)?
    var generation = 0
    let languages = [("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("English", "en"), ("日本語", "ja"), ("한국어", "ko"), ("Français", "fr"), ("Deutsch", "de"), ("Español", "es")]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--verify-pinning") {
            verifyPinning(); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--verify-selection") {
            verifySelectionHotkey()
            NSApp.terminate(nil)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preview-shortcuts"), CommandLine.arguments.count > index + 1 {
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let root = self.settings!.contentView!
                root.wantsLayer = true
                root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                root.layoutSubtreeIfNeeded()
                self.settings!.displayIfNeeded()
                let stack = root.subviews.first as! NSStackView
                let layout = "root=\(root.bounds)\n" + stack.arrangedSubviews.map { "\(type(of: $0)) \(stack.convert($0.frame, to: root)) ambiguous=\($0.hasAmbiguousLayout)" }.joined(separator: "\n")
                try? layout.write(toFile: CommandLine.arguments[index + 1] + ".layout.txt", atomically: true, encoding: .utf8)
                precondition(stack.arrangedSubviews.allSatisfy { !$0.hasAmbiguousLayout && root.bounds.contains(stack.convert($0.frame, to: root)) }, "Settings controls must fit within the window")
                let defaultHelp = self.shortcutStatus!.stringValue
                self.shortcutStatus!.stringValue = HotKey.Failure.systemConflict.message + " 已保留原快捷键。"
                root.layoutSubtreeIfNeeded()
                precondition(stack.arrangedSubviews.allSatisfy { root.bounds.contains(stack.convert($0.frame, to: root)) }, "Conflict explanation must not push controls outside the window")
                self.shortcutStatus!.stringValue = defaultHelp
                root.layoutSubtreeIfNeeded()
                if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
                print("PASS: shortcut presets and settings layout")
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--verify-maintenance") {
            let service = AppMaintenance(); service.verifySetup(); NSApp.terminate(nil); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-update-feed"), CommandLine.arguments.count > index + 1 {
            let service = AppMaintenance(); self.maintenance = service
            service.probeFeed = CommandLine.arguments[index + 1]
            do { try service.start(); service.controller.updater.checkForUpdateInformation() }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("FAIL: update feed check timed out"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preview-maintenance"), CommandLine.arguments.count > index + 1 {
            showMaintenance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let view = self.maintenanceWindow!.contentView!
                view.wantsLayer = true; view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                view.layoutSubtreeIfNeeded(); self.maintenanceWindow!.displayIfNeeded()
                precondition(view.subviews.allSatisfy { !$0.hasAmbiguousLayout })
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
                print("PASS: update and integrated uninstall settings layout")
                NSApp.terminate(nil)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
            createPanel()
            sourceView.string = "Select any word or sentence, then press your shortcut."
            sourceText = sourceView.string
            resultView.string = "选中任意单词或句子，然后按下快捷键。"
            if CommandLine.arguments.contains("--preview-format") {
                self.panel.setContentSize(NSSize(width: 570, height: 640))
                self.sourceText = "• UGTA Debugger: attacks the nearest zombie on the same row.\n• AI Cannon: attacks every zombie up to CANNON_RANGE cells to the right.\n• Redbird Bomb: attacks every zombie in a 3×3 block.\n• Coffeeflower and Wall: produce no markers."
                self.translatedText = "• UGTA 调试器：攻击同一行中距离最近的僵尸。\n• AI 大炮：攻击右侧 CANNON_RANGE 范围内的所有僵尸。\n• 红鸟炸弹：攻击 3×3 区域内的所有僵尸。\n• 咖啡花与墙：不生成攻击标记。"
                self.sourceView.textStorage?.setAttributedString(SelectionFormatting.display(nil, text: self.sourceText, size: 15))
                self.resultView.textStorage?.setAttributedString(SelectionFormatting.display(nil, text: self.translatedText, size: 19))
            }
            message.stringValue = "新选区翻译 · 同文关闭 · Esc"
            copyButton.isEnabled = true
            panel.appearance = NSAppearance(named: .aqua)
            panel.center()
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let root = self.panel.contentView!
                root.layoutSubtreeIfNeeded()
                self.panel.displayIfNeeded()
                if CommandLine.arguments.contains("--verify-ui") {
                    precondition(self.panel.isVisible, "Preview must be visible")
                    let effect = root as! NSVisualEffectView
                    precondition(effect.material == .popover && effect.blendingMode == .behindWindow, "Use native backdrop blur")
                    precondition(!self.panel.isOpaque && self.panel.backgroundColor == .clear, "Keep the window background transparent")
                    precondition(root.subviews.allSatisfy { !$0.hasAmbiguousLayout }, "Window layout must be unambiguous")
                    self.selectionReaderForVerification = { complete in complete(self.sourceText) }
                    let previousGeneration = self.generation
                    let serviceToken = self.translationService.token
                    self.handleShortcut()
                    precondition(!self.panel.isVisible, "Same selection must dismiss")
                    precondition(self.generation > previousGeneration && self.translationService.token != serviceToken, "Dismiss must invalidate pending results")
                    self.panel.orderFrontRegardless()
                    self.panel.cancelOperation(nil)
                    precondition(!self.panel.isVisible, "Escape must dismiss")
                    self.panel.orderFrontRegardless()
                    self.panel.performClose(nil)
                    precondition(!self.panel.isVisible, "Window close must dismiss")
                    self.panel.orderFrontRegardless()
                    self.handleShortcut()
                    precondition(!self.panel.isVisible, "Repeated show/hide must work")
                    print("PASS: native blur, layout, same-selection dismissal, request cancellation, Escape, window close, repeated dismissal")
                    self.panel.orderFrontRegardless()
                }
                let frames = root.subviews.map { "\(type(of: $0)) \($0.frame) ambiguous=\($0.hasAmbiguousLayout)" }.joined(separator: "\n")
                try? frames.write(toFile: CommandLine.arguments[index + 1] + ".layout.txt", atomically: true, encoding: .utf8)
                if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        if let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            alert("已有一个翻译应用在运行", "请先从菜单栏退出原来的副本，再打开新版。运行中的位置：\(other.bundleURL?.path ?? "未知")")
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "划词谷歌翻译")
        let menu = NSMenu()
        for (title, selector) in [("翻译剪贴板", #selector(translateClipboard)), ("设置…", #selector(showSettings)), ("检查更新…", #selector(checkForUpdates)), ("辅助功能权限…", #selector(openAccessibility)), ("退出", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        maintenance = AppMaintenance()
        do { try maintenance?.start() } catch { NSLog("更新组件未启动：%@", error.localizedDescription) }
        if UserDefaults.standard.string(forKey: "translationBackend") == "chrome" { ChromeBridge.shared.start() }
        createPanel()
        hotKey.action = { [weak self] in self?.handleShortcut() }
        if !hotKey.register(shortcut) {
            showSettings()
            shortcutStatus?.stringValue = hotKey.lastFailure?.message ?? "快捷键无法注册，请重新设置。"
            alert("快捷键被占用", hotKey.lastFailure?.message ?? "请在设置中录入另一个快捷键。")
        } else if !UserDefaults.standard.bool(forKey: "backgroundBrowser14") {
            UserDefaults.standard.set(true, forKey: "backgroundBrowser14")
            UserDefaults.standard.set("browser", forKey: "translationBackend")
            showSettings()
        } else if !UserDefaults.standard.bool(forKey: "introduced") {
            UserDefaults.standard.set(true, forKey: "introduced")
            showSettings()
        }
    }

    func textArea(font: NSFont) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = font
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 2, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return (scroll, text)
    }
    func createPanel() {
        panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "划词翻译"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .normal
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 400, height: 360)
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.closePanel() }
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        panel.contentView = root
        let title = NSTextField(labelWithString: "划词翻译")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        languageLabel = NSTextField(labelWithString: "自动识别 → 简体中文")
        languageLabel.font = .systemFont(ofSize: 11)
        languageLabel.textColor = .secondaryLabelColor
        languageLabel.lineBreakMode = .byTruncatingTail
        pinButton = NSButton(title: "置顶", target: self, action: #selector(togglePin))
        pinButton.bezelStyle = .rounded
        pinButton.controlSize = .small
        updatePinAppearance()
        let originalCard = GlassCard(frame: .zero)
        let translatedCard = GlassCard(frame: .zero)
        let originalLabel = NSTextField(labelWithString: "原文")
        originalLabel.font = .systemFont(ofSize: 11, weight: .medium)
        originalLabel.textColor = .secondaryLabelColor
        let translatedLabel = NSTextField(labelWithString: "译文")
        translatedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        translatedLabel.textColor = .systemBlue
        let (originalScroll, original) = textArea(font: .systemFont(ofSize: 15))
        sourceView = original
        let (resultScroll, result) = textArea(font: .systemFont(ofSize: 19))
        resultView = result
        message = NSTextField(labelWithString: "新选区翻译 · 同文关闭 · Esc")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        retryButton = NSButton(title: "重试", target: self, action: #selector(retryTranslation))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        copyButton = NSButton(title: "复制译文", target: self, action: #selector(copyTranslation))
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false
        if let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) {
            copyButton.image = image
            copyButton.imagePosition = .imageLeading
        }
        let footer = NSStackView(views: [spinner, message, retryButton, copyButton])
        footer.distribution = .fill
        footer.spacing = 8
        for view in [title, languageLabel!, pinButton!, originalCard, translatedCard, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for (card, label, scroll) in [(originalCard, originalLabel, originalScroll), (translatedCard, translatedLabel, resultScroll)] {
            label.translatesAutoresizingMaskIntoConstraints = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(label)
            card.addSubview(scroll)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 5),
                scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
            ])
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 86),
            languageLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            languageLabel.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -10),
            languageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            pinButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            originalCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            originalCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            originalCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            originalCard.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.29),
            translatedCard.topAnchor.constraint(equalTo: originalCard.bottomAnchor, constant: 10),
            translatedCard.leadingAnchor.constraint(equalTo: originalCard.leadingAnchor),
            translatedCard.trailingAnchor.constraint(equalTo: originalCard.trailingAnchor),
            translatedCard.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
    }
    func handleShortcut() {
        guard recorder?.recording != true else { return }
        selectionRevision += 1
        // Serialize reads so a second copy chord cannot overwrite another read's clipboard snapshot.
        // Only the most recent shortcut request may update or dismiss the window.
        if busy { readSelectionAgain = true; return }
        translateSelection()
    }
    func verifySelectionHotkey() {
        createPanel()
        var reads: [(String?) -> Void] = []
        var requests: [(String, (Result<String, Error>) -> Void)] = []
        selectionReaderForVerification = { reads.append($0) }
        translatorForVerification = { text, _, complete in requests.append((text, complete)) }
        func read(_ text: String?) { let complete = reads.removeFirst(); complete(text) }
        func check(_ value: Bool, _ description: String) {
            precondition(value, description)
            print("PASS: \(description)")
        }
        handleShortcut()
        check(busy && reads.count == 1 && !panel.isVisible, "Hidden panel starts a selection read")
        read("  First selection\n")
        check(panel.isVisible && sourceText == "First selection" && requests.count == 1, "First selection opens a translation")
        let firstGeneration = generation
        handleShortcut(); read("Second selection")
        check(panel.isVisible && sourceText == "Second selection" && requests.count == 2 && generation > firstGeneration, "New selection replaces the pending translation without hiding")
        requests[0].1(.success("Late first result"))
        check(resultView.string == "正在翻译…", "Old translation completion cannot overwrite new selection")
        requests[1].1(.success("Second result"))
        check(resultView.string == "Second result" && copyButton.isEnabled, "Latest translation result is displayed")
        handleShortcut(); read("First selection")
        check(panel.isVisible && sourceText == "First selection" && requests.count == 3, "Previously translated text is translated again when current source differs")
        let token = translationService.token
        handleShortcut(); read("\n First selection \t")
        check(!panel.isVisible && requests.count == 3 && translationService.token != token, "Same selection closes while translating and cancels pending results")
        requests[2].1(.success("Late result after close"))
        check(!panel.isVisible && resultView.string == "正在翻译…", "Late result cannot reopen the closed panel")
        handleShortcut(); read("First selection")
        check(panel.isVisible && requests.count == 4, "Hidden panel translates the same text again")
        requests[3].1(.success("Keep this result"))
        for missing in [nil, "", " \n\t"] as [String?] {
            handleShortcut(); read(missing)
            check(panel.isVisible && resultView.string == "Keep this result" && requests.count == 4, "Unreadable or empty selection preserves the current translation")
        }
        handleShortcut(); read(String(repeating: "中", count: 5001))
        check(panel.isVisible && resultView.string == "Keep this result" && requests.count == 4, "Oversized selection preserves current translation")
        handleShortcut()
        handleShortcut()
        handleShortcut()
        check(reads.count == 1 && readSelectionAgain, "Rapid shortcuts serialize selection reads")
        read("Stale selection")
        check(reads.count == 1 && requests.count == 4 && sourceText == "First selection", "Obsolete read is discarded and newest read is started")
        read("Latest selection")
        check(panel.isVisible && sourceText == "Latest selection" && requests.count == 5 && !busy, "Only the latest selection request updates the panel")
        handleShortcut()
        panel.cancelOperation(nil)
        read("Selection arriving after Escape")
        check(!panel.isVisible && requests.count == 5 && !busy, "Escape invalidates an in-flight selection read")
        handleShortcut()
        handleShortcut()
        closePanel()
        read("Cancelled queued selection")
        check(reads.isEmpty && !readSelectionAgain && !busy && !panel.isVisible, "Closing clears queued reads and prevents reopening")
        handleShortcut()
        closePanel()
        handleShortcut()
        read("Obsolete read from before close")
        check(!panel.isVisible && reads.count == 1 && requests.count == 5, "A fresh shortcut after close waits for old read cleanup")
        read("Reopened selection")
        check(panel.isVisible && sourceText == "Reopened selection" && requests.count == 6, "Fresh shortcut after close opens only the newly selected text")
        closePanel()
        handleShortcut(); read("Last selection")
        let record = Recorder()
        recorder = record; record.recording = true
        handleShortcut()
        check(reads.isEmpty && panel.isVisible, "Shortcut recording does not trigger translation or dismissal")
        record.recording = false
        handleShortcut()
        startRecording()
        read("Obsolete read while editing shortcut")
        check(panel.isVisible && sourceText == "Last selection" && !busy, "Starting shortcut recording cancels an in-flight selection read")
        record.recording = false
        panel.performClose(nil)
        check(!panel.isVisible, "Window close still dismisses")
        check(!busy && reads.isEmpty, "Selection reader returns to idle")
        print("All selection-aware shortcut checks passed; no network, clipboard or permissions changed.")
    }
    func consumeSelection(_ raw: String, formatting: NSAttributedString? = nil) {
        let text: String
        do { text = try TranslationRequest.normalize(raw) }
        catch { selectionFailed(error.localizedDescription); return }
        if panel.isVisible && text.trimmingCharacters(in: .whitespacesAndNewlines) == sourceText.trimmingCharacters(in: .whitespacesAndNewlines) { closePanel() }
        else { showTranslation(text, formatting: formatting) }
    }
    func selectionFailed(_ text: String) {
        if panel.isVisible {
            // Failure to read a selection is not evidence that it matches the current source.
            message.stringValue = "未读到有效新选区 · Esc 关闭"
            message.toolTip = text
        } else { showMessage(text) }
    }
    func finishSelectionRead() {
        busy = false
        if readSelectionAgain {
            readSelectionAgain = false
            translateSelection()
        }
    }
    func invalidateSelectionReads() {
        selectionRevision += 1
        readSelectionAgain = false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { closePanel(); return false }
        return true
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel { hideForOutsideInteraction() }
    }
    func hideForOutsideInteraction() {
        guard panelPresented, !isPinned else { return }
        closePanel()
    }
    func beginOutsideMonitoring() {
        guard outsideClickMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in self?.hideForOutsideInteraction() }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            if let self, event.window !== self.panel { self.hideForOutsideInteraction() }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.hideForOutsideInteraction()
        }
    }
    func endOutsideMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        outsideClickMonitor = nil; localClickMonitor = nil; activationObserver = nil
    }
    func updatePinAppearance() {
        pinButton.title = isPinned ? "已置顶" : "置顶"
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.imagePosition = .imageLeading
        pinButton.contentTintColor = isPinned ? .systemBlue : .secondaryLabelColor
        pinButton.toolTip = isPinned ? "取消置顶；点击其他窗口后自动隐藏" : "开启置顶；切换窗口后继续显示"
        pinButton.setAccessibilityLabel(isPinned ? "取消置顶" : "开启置顶")
    }
    @objc func togglePin() {
        isPinned.toggle()
        panel.hidesOnDeactivate = !isPinned
        panel.level = isPinned ? .floating : .normal
        panel.collectionBehavior = isPinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        updatePinAppearance()
        if panelPresented { panel.orderFrontRegardless() }
    }
    func verifyPinning() {
        createPanel()
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); print("PASS: " + label) }
        var late: ((Result<String, Error>) -> Void)?
        translatorForVerification = { _, _, complete in late = complete }
        showTranslation("• First: item\n• Second: item")
        check(!isPinned && panel.level == .normal && panel.hidesOnDeactivate, "Default panel is unpinned")
        check(outsideClickMonitor != nil && localClickMonitor != nil && activationObserver != nil, "Monitor clicks in the same app, other apps and activation changes")
        hideForOutsideInteraction()
        check(!panel.isVisible && outsideClickMonitor == nil, "Outside interaction hides and removes monitors")
        late?(.success("Late result"))
        check(!panel.isVisible && !copyButton.isEnabled, "Hidden panel ignores late translation")
        showTranslation("Pinned text")
        togglePin()
        check(isPinned && panel.level == .floating && !panel.hidesOnDeactivate && pinButton.title == "已置顶", "Dedicated pin button enables persistent floating mode")
        hideForOutsideInteraction()
        check(panel.isVisible, "Pinned panel survives outside clicks")
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.makeKeyAndOrderFront(nil)
        check(panel.isVisible, "Pinned panel survives another window becoming key")
        panel.makeKeyAndOrderFront(nil)
        togglePin()
        hideForOutsideInteraction()
        check(!panel.isVisible && !isPinned, "Unpin restores automatic hiding")
        showTranslation("Close while pinned"); togglePin(); panel.cancelOperation(nil)
        check(!panel.isVisible && localClickMonitor == nil, "Escape still closes a pinned panel")
        other.orderOut(nil)
        print("All pinning checks passed; no preferences or permissions changed.")
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    func selectedText(in application: AXUIElement) -> String? {
        guard let focused = elementAttribute(application, kAXFocusedUIElementAttribute) else { return nil }
        if attribute(focused, kAXSubroleAttribute) as? String == "AXSecureTextField" { return "" }
        var element: AXUIElement? = focused
        for _ in 0..<12 {
            guard let current = element else { break }
            if let text = attribute(current, kAXSelectedTextAttribute) as? String, !text.isEmpty { return text }
            // Chromium often exposes page selections through text markers on a web area.
            if let range = attribute(current, "AXSelectedTextMarkerRange") {
                var text: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(current, "AXStringForTextMarkerRange" as CFString, range, &text) == .success,
                   let value = text as? String, !value.isEmpty { return value }
            }
            element = elementAttribute(current, kAXParentAttribute)
        }
        return nil
    }
    func translateSelection() {
        guard !busy, recorder?.recording != true else { return }
        let revision = selectionRevision
        if let reader = selectionReaderForVerification {
            busy = true
            reader { [weak self] text in
                guard let self else { return }
                defer { self.finishSelectionRead() }
                guard self.selectionRevision == revision else { return }
                if let text { self.consumeSelection(text) }
                else { self.selectionFailed("没有读到选区。请选择文字后重试。") }
            }
            return
        }
        guard AccessibilityPermission.check() else {
            selectionFailed("本次运行尚未获得读取权限。若开关已打开，请退出本应用，移除旧的权限条目，用 + 添加新版后再打开。设置页可查看当前运行位置。")
            openAccessibility()
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            selectionFailed("请回到 Chrome 或其他软件，选中文字后再按快捷键。")
            return
        }
        let pid = front.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        busy = true
        Task { @MainActor in
            defer { self.finishSelectionRead() }
            guard self.selectionRevision == revision else { return }
            let isChromium = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium", "company.thebrowser.Browser"].contains { (front.bundleIdentifier ?? "").hasPrefix($0) }
            if isChromium {
                AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                if let window = self.elementAttribute(application, kAXFocusedWindowAttribute) {
                    AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                }
            }
            var plainSelection: String?
            for attempt in 0..<(isChromium ? 3 : 1) {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 150_000_000) }
                guard self.selectionRevision == revision else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    self.selectionFailed("请回到选中文字的软件后重试。"); return
                }
                if let text = self.selectedText(in: application) {
                    if text.isEmpty { self.consumeSelection(text); return }
                    plainSelection = text
                    // Chromium text markers can flatten list boundaries. Prefer its
                    // copied HTML/RTF, with AX text retained if copying is unavailable.
                    if !isChromium && !text.contains("\n") { self.consumeSelection(text); return }
                    break
                }
            }
            var attempts = 0
            while !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty && attempts < 120 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard self.selectionRevision == revision else { return }
                attempts += 1
            }
            guard self.selectionRevision == revision else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                self.selectionFailed("请回到选中文字的软件后重试。"); return
            }
            guard NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                self.selectionFailed("请松开快捷键后重试。"); return
            }
            let clipboard = NSPasteboard.general
            let snapshot: [[NSPasteboard.PasteboardType: Data]] = (clipboard.pasteboardItems ?? []).map { item in
                var contents: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types { if let data = item.data(forType: type) { contents[type] = data } }
                return contents
            }
            let before = clipboard.changeCount
            guard let source = CGEventSource(stateID: .privateState),
                  let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false),
                  let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else {
                self.selectionFailed("无法读取选区，请复制文字后从菜单翻译剪贴板。"); return
            }
            // Post the full copy chord to the captured app, with no inherited hotkey flags.
            commandDown.flags = .maskCommand; down.flags = .maskCommand; up.flags = .maskCommand; commandUp.flags = []
            commandDown.postToPid(pid)
            down.postToPid(pid)
            try? await Task.sleep(nanoseconds: 25_000_000)
            up.postToPid(pid)
            commandUp.postToPid(pid)
            var copied: String?
            var copiedCount: Int?
            var formatting: NSAttributedString?
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { break }
                if clipboard.changeCount != before {
                    // Chrome can publish clipboard formats in stages.
                    if let value = clipboard.string(forType: .string), !value.isEmpty {
                        copied = value; copiedCount = clipboard.changeCount
                        formatting = SelectionFormatting.fromClipboard(clipboard)
                        if let formatting, !formatting.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { copied = formatting.string }
                        break
                    }
                }
            }
            if let copiedCount, clipboard.changeCount == copiedCount {
                clipboard.clearContents()
                let items = snapshot.map { contents -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in contents { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { clipboard.writeObjects(items) }
            }
            // Always release the copy chord and restore its clipboard before retiring a stale read.
            guard self.selectionRevision == revision else { return }
            if let copied { self.consumeSelection(copied, formatting: formatting) }
            else if let plainSelection { self.consumeSelection(plainSelection) }
            else { self.selectionFailed("没有读到选区。请确认辅助功能权限已开启，也可先按 ⌘C，再从菜单选择“翻译剪贴板”。") }
        }
    }

    func presentPanel() {
        panelPresented = true
        beginOutsideMonitoring()
        if !panel.isVisible {
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
            if let screen {
                let visible = screen.visibleFrame
                let x = max(visible.minX, min(point.x + 12, visible.maxX - panel.frame.width))
                let y = max(visible.minY, min(point.y - panel.frame.height - 12, visible.maxY - panel.frame.height))
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }
    func showMessage(_ text: String) {
        generation += 1
        translationService.cancel()
        spinner.stopAnimation(nil)
        sourceText = ""; translatedText = ""
        sourceFormatting = nil
        sourceView.string = ""
        resultView.string = text
        resultView.textColor = .labelColor
        message.stringValue = "选中文字后按 " + shortcut.label
        message.toolTip = nil
        copyButton.isEnabled = false
        retryButton.isHidden = true
        presentPanel()
    }
    func showTranslation(_ raw: String, formatting: NSAttributedString? = nil) {
        let text: String
        do { text = try TranslationRequest.normalize(raw) }
        catch { showMessage(error.localizedDescription); return }
        let target = UserDefaults.standard.string(forKey: "targetLanguage") ?? "zh-CN"
        let chrome = ["chrome", "browser"].contains(UserDefaults.standard.string(forKey: "translationBackend") ?? "google")
        let source = UserDefaults.standard.string(forKey: "chromeSourceLanguage") ?? "en"
        let sourceName = chrome ? (languages.first(where: { $0.1 == source })?.0 ?? source) : "自动识别"
        languageLabel.stringValue = sourceName + " → " + (languages.first(where: { $0.1 == target })?.0 ?? target)
        sourceText = text; translatedText = ""
        sourceFormatting = formatting
        message.toolTip = nil
        sourceView.textStorage?.setAttributedString(SelectionFormatting.display(formatting, text: text, size: 15))
        sourceView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        resultView.string = "正在翻译…"
        resultView.textColor = .secondaryLabelColor
        copyButton.isEnabled = false
        retryButton.isHidden = true
        spinner.startAnimation(nil)
        message.stringValue = chrome ? "网页高级翻译中…" : "Google 翻译"
        generation += 1
        let requestGeneration = generation
        presentPanel()
        let completion: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self, self.generation == requestGeneration else { return }
            self.spinner.stopAnimation(nil)
            self.resultView.textColor = .labelColor
            switch result {
            case .success(let translated):
                self.translatedText = translated
                self.resultView.textStorage?.setAttributedString(SelectionFormatting.display(nil, text: translated, size: 19))
                self.resultView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                self.copyButton.isEnabled = true
                self.message.stringValue = "新选区翻译 · 同文关闭 · Esc"
            case .failure(let error):
                self.resultView.string = error.localizedDescription
                self.retryButton.isHidden = false
                self.message.stringValue = "连接失败"
            }
        }
        if let translator = translatorForVerification {
            translationService.cancel()
            translator(text, target, completion)
        } else { translationService.translate(text: text, target: target, completion: completion) }
    }
    @objc func retryTranslation() {
        if !sourceText.isEmpty { invalidateSelectionReads(); showTranslation(sourceText, formatting: sourceFormatting) }
    }
    @objc func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
        message.stringValue = "译文已复制"
    }
    @objc func translateClipboard() {
        invalidateSelectionReads()
        let clipboard = NSPasteboard.general
        let formatting = SelectionFormatting.fromClipboard(clipboard)
        showTranslation(formatting?.string ?? clipboard.string(forType: .string) ?? "", formatting: formatting)
    }
    @objc func closePanel() {
        panelPresented = false
        endOutsideMonitoring()
        invalidateSelectionReads()
        generation += 1
        translationService.cancel()
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func openAccessibility() {
        AccessibilityPermission.request()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func showSettings() {
        if let settings { updatePermissionStatus(); NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "划词谷歌翻译 · 设置"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "选中文字，一键翻译")
        title.font = .boldSystemFont(ofSize: 19)
        let intro = NSTextField(wrappingLabelWithString: "选新文字直接翻译，同文再按关闭。磨砂半透明浮窗显示原文和译文，默认免密钥。")
        intro.preferredMaxLayoutWidth = 452
        let shortcutTitle = NSTextField(labelWithString: "全局快捷键（点击后按下新组合）")
        let record = Recorder(title: shortcut.label, target: self, action: #selector(startRecording))
        record.bezelStyle = .rounded
        record.changed = { [weak self] candidate in self?.applyShortcut(candidate) }
        record.cancel = { [weak self, weak record] in
            guard let self, let record else { return }
            record.recording = false
            record.title = self.shortcut.label
            if !self.hotKey.register(self.shortcut) {
                self.shortcutStatus?.stringValue = self.hotKey.lastFailure?.message ?? "快捷键无法注册，请重新设置。"
            }
        }
        self.recorder = record
        let spaces = NSPopUpButton()
        spaces.addItems(withTitles: ["选择空格组合…", "Control + 空格", "Option + 空格", "Command + 空格"])
        spaces.target = self; spaces.action = #selector(spaceShortcutChosen(_:))
        let shortcutRow = NSStackView(views: [record, spaces])
        shortcutRow.spacing = 10
        let shortcutHelp = NSTextField(wrappingLabelWithString: "支持修饰键 + 空格。⌘ 空格通常用于 Spotlight，⌃ 空格通常用于切换输入法；被占用时请先更改系统的对应快捷键。")
        shortcutHelp.font = .systemFont(ofSize: 11)
        shortcutHelp.textColor = .secondaryLabelColor
        shortcutHelp.preferredMaxLayoutWidth = 452
        shortcutStatus = shortcutHelp
        let row = NSStackView()
        row.addArrangedSubview(NSTextField(labelWithString: "目标语言"))
        let language = NSPopUpButton()
        language.addItems(withTitles: languages.map { $0.0 })
        language.selectItem(at: languages.firstIndex { $0.1 == (UserDefaults.standard.string(forKey: "targetLanguage") ?? "zh-CN") } ?? 0)
        language.target = self; language.action = #selector(languageChanged(_:))
        row.addArrangedSubview(language)
        let engine = NSPopUpButton()
        engine.addItems(withTitles: ["Google 普通翻译", "后台浏览器高级（Gemini）"])
        engine.selectItem(at: UserDefaults.standard.string(forKey: "translationBackend") == "browser" ? 1 : 0)
        engine.target = self; engine.action = #selector(engineChanged(_:))
        let engineRow = NSStackView(views: [NSTextField(labelWithString: "翻译方式"), engine])
        let source = NSPopUpButton()
        source.addItems(withTitles: languages.map { $0.0 })
        source.selectItem(at: languages.firstIndex { $0.1 == (UserDefaults.standard.string(forKey: "chromeSourceLanguage") ?? "en") } ?? 2)
        source.target = self; source.action = #selector(sourceChanged(_:))
        let sourceRow = NSStackView(views: [NSTextField(labelWithString: "网页高级 · 原文语言"), source])
        let connectChrome = NSButton(title: "后台浏览器与 Google 登录…", target: self, action: #selector(showBrowserSetup))
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        permissionLabel = status
        let permissions = NSButton(title: "申请读取权限…", target: self, action: #selector(openAccessibility))
        let locate = NSButton(title: "显示当前应用位置", target: self, action: #selector(revealCurrentApp))
        let restart = NSButton(title: "重新启动应用", target: self, action: #selector(restartApp))
        let permissionActions = NSStackView(views: [permissions, locate, restart])
        permissionActions.spacing = 8
        let path = NSTextField(labelWithString: Bundle.main.bundleURL.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.isSelectable = true
        path.toolTip = Bundle.main.bundleURL.path

        let help = NSTextField(wrappingLabelWithString: "授权时，请在系统的“辅助功能”或“Device Control and Data Access”页面添加当前应用。开关已开却无效：先退出应用、移除旧条目，再用 + 添加当前副本后重新打开。翻译需要能访问 Google；不保存翻译历史。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 452
        let cloud = NSButton(title: "Google Cloud 连接（可选）…", target: self, action: #selector(configureCloud))
        let maintenanceButton = NSButton(title: "软件更新与卸载…", target: self, action: #selector(showMaintenance))
        let stack = NSStackView(views: [title, intro, shortcutTitle, shortcutRow, shortcutHelp, row, engineRow, sourceRow, connectChrome, status, permissionActions, path, cloud, maintenanceButton, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        for horizontalRow in [shortcutRow, row, engineRow, sourceRow, permissionActions] {
            horizontalRow.distribution = .fill
            horizontalRow.alignment = .centerY
            horizontalRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            path.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            if self?.recorder?.recording == true { self?.recorder?.cancel?() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            if self?.recorder?.recording == true { self?.recorder?.cancel?() }
        }
        self.settings = window
        updatePermissionStatus()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard self?.settings?.isVisible == true || self?.chromeWindow?.isVisible == true || self?.browserWindow?.isVisible == true else { return }
            self?.updatePermissionStatus()
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func updatePermissionStatus() {
        browserStatus?.stringValue = BackgroundBrowser.shared.statusText
        chromeStatus?.stringValue = ChromeBridge.shared.connected ? "Chrome：已连接 · 请保持翻译页打开" : "Chrome：等待扩展连接"
        let trusted = AccessibilityPermission.check()
        permissionLabel?.stringValue = trusted ? "读取权限：已生效" : "读取权限：尚未确认 · 授权后可重新启动"
        permissionLabel?.textColor = trusted ? .systemGreen : .secondaryLabelColor
    }
    @objc func revealCurrentApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    @objc func restartApp() {
        // Schedule an ordinary app launch after this process has exited. Do not reset TCC.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$1\"", "quicktranslate-restart", Bundle.main.bundleURL.path]
        do { try process.run(); NSApp.terminate(nil) }
        catch { alert("请手动重新打开", "从菜单栏退出本应用，然后从应用程序文件夹重新打开。") }
    }
    @objc func startRecording() {
        if recorder?.recording == true { recorder?.cancel?(); return }
        invalidateSelectionReads()
        hotKey.unregister()
        recorder?.recording = true
        recorder?.title = "请按快捷键 · Esc 取消"
        settings?.makeFirstResponder(recorder)
    }
    func applyShortcut(_ candidate: Shortcut) {
        recorder?.recording = false
        if hotKey.register(candidate) {
            shortcut = candidate
            candidate.save()
            recorder?.title = candidate.label
            shortcutStatus?.stringValue = "已设置为 \(candidate.label)。选新文字直接翻译，同文再按关闭。"
        } else {
            let failure = hotKey.lastFailure?.message ?? "快捷键无法注册。"
            let restored = hotKey.register(shortcut)
            recorder?.title = shortcut.label
            shortcutStatus?.stringValue = failure + (restored ? " 已保留原快捷键。" : " 请重新选择快捷键。")
        }
    }
    @objc func spaceShortcutChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        sender.selectItem(at: 0)
        guard Shortcut.spaceChoices.indices.contains(index) else { return }
        applyShortcut(Shortcut.spaceChoices[index])
    }
    @objc func languageChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(languages[sender.indexOfSelectedItem].1, forKey: "targetLanguage")
    }
    @objc func engineChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1 ? "browser" : "google", forKey: "translationBackend")
        if sender.indexOfSelectedItem == 1 { showBrowserSetup() }
    }
    @objc func sourceChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(languages[sender.indexOfSelectedItem].1, forKey: "chromeSourceLanguage")
    }
    @objc func showBrowserSetup() {
        if let browserWindow { NSApp.activate(ignoringOtherApps: true); browserWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "后台浏览器与 Google 登录"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "登录一次，之后在后台翻译")
        title.font = .boldSystemFont(ofSize: 18)
        let instructions = NSTextField(wrappingLabelWithString: "首次点击“打开登录窗口”，在专用 Chrome 窗口登录 Google，并确认翻译页面的高级模式。完成后点击“转入后台”，浏览器窗口会关闭，翻译只显示在磨砂浮窗中。\n\n使用本机安装的 Chrome 引擎，无需扩展。专用浏览器独立保存登录状态；登录失效或需要验证时，请重新打开登录窗口。")
        instructions.font = .systemFont(ofSize: 13)
        let status = NSTextField(labelWithString: BackgroundBrowser.shared.statusText)
        status.font = .systemFont(ofSize: 12)
        browserStatus = status
        let login = NSButton(title: "打开登录窗口", target: self, action: #selector(openBrowserLogin))
        let background = NSButton(title: "转入后台", target: self, action: #selector(activateBackgroundBrowser))
        let stop = NSButton(title: "停止后台浏览器", target: self, action: #selector(stopBackgroundBrowser))
        let actions = NSStackView(views: [login, background, stop])
        actions.spacing = 8
        let stack = NSStackView(views: [title, instructions, status, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        browserWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func openBrowserLogin() {
        closePanel()
        Task { @MainActor in
            do { try await BackgroundBrowser.shared.launchLogin(); browserStatus?.stringValue = BackgroundBrowser.shared.statusText }
            catch { alert("浏览器未能打开", error.localizedDescription) }
        }
    }
    @objc func activateBackgroundBrowser() {
        closePanel()
        browserStatus?.stringValue = "正在转入后台…"
        Task { @MainActor in
            do { try await BackgroundBrowser.shared.startBackground(); browserStatus?.stringValue = BackgroundBrowser.shared.statusText }
            catch { alert("后台浏览器未启动", error.localizedDescription) }
        }
    }
    @objc func stopBackgroundBrowser() {
        closePanel()
        Task { @MainActor in
            do { try await BackgroundBrowser.shared.stop(); browserStatus?.stringValue = BackgroundBrowser.shared.statusText }
            catch { alert("浏览器尚未退出", error.localizedDescription) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { BackgroundBrowser.shared.terminateOwnedProcess() }
    @objc func checkForUpdates() {
        if maintenance == nil { maintenance = AppMaintenance() }
        do { try maintenance!.checkForUpdates() } catch { alert("暂时无法检查更新", error.localizedDescription) }
    }
    @objc func showMaintenance() {
        if let maintenanceWindow { NSApp.activate(ignoringOtherApps: true); maintenanceWindow.makeKeyAndOrderFront(nil); return }
        if maintenance == nil { maintenance = AppMaintenance() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "软件更新与卸载"; window.isReleasedWhenClosed = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSTextField(labelWithString: "划词谷歌翻译 · \(version)"); title.font = .boldSystemFont(ofSize: 19)
        let description = NSTextField(wrappingLabelWithString: "有新版本时，优先下载增量更新，确认后自动更新并重启。更新会保留快捷键、语言和 Google 登录资料。")
        let check = NSButton(title: "检查更新…", target: self, action: #selector(checkForUpdates))
        let automatic = NSButton(checkboxWithTitle: "自动检查新版本", target: self, action: #selector(automaticUpdatesChanged(_:)))
        automatic.state = maintenance!.automaticChecks ? .on : .off
        let separator = NSBox(); separator.boxType = .separator
        let removeText = NSTextField(wrappingLabelWithString: "不再使用时，可查看应用和残留清单，选择要清理的内容。卸载前会再次确认。")
        let uninstall = NSButton(title: "卸载此软件…", target: self, action: #selector(openUninstaller)); uninstall.hasDestructiveAction = true
        let stack = NSStackView(views: [title, description, check, automatic, separator, removeText, uninstall]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), separator.widthAnchor.constraint(equalTo: stack.widthAnchor), description.widthAnchor.constraint(equalTo: stack.widthAnchor), removeText.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        maintenanceWindow = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc func automaticUpdatesChanged(_ button: NSButton) { maintenance?.automaticChecks = button.state == .on }
    @objc func openUninstaller() {
        closePanel()
        if maintenance == nil { maintenance = AppMaintenance() }
        do { try maintenance!.openUninstaller() } catch { alert("无法打开卸载工具", error.localizedDescription) }
    }
    @objc func showChromeConnection() {
        if let chromeWindow { NSApp.activate(ignoringOtherApps: true); chromeWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Chrome 高级模式连接"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "沿用 Chrome 的 Google 登录")
        title.font = .boldSystemFont(ofSize: 18)
        let instructions = NSTextField(wrappingLabelWithString: "1. 打开 chrome://extensions，开启开发者模式。\n2. 点击“加载已解压的扩展程序”，选择配套扩展文件夹。\n3. 在 Chrome 扩展按钮中粘贴连接码并保存。\n4. 点击“打开专用翻译页”，登录 Google 并选择高级。\n\n请保持专用翻译标签页打开。语言组合没有高级选项时，会提示失败，不会改用经典模型。")
        instructions.font = .systemFont(ofSize: 13)
        let status = NSTextField(labelWithString: "Chrome：等待扩展连接")
        chromeStatus = status
        let copy = NSButton(title: "复制连接码", target: self, action: #selector(copyPairingCode))
        let locate = NSButton(title: "显示扩展文件夹", target: self, action: #selector(revealChromeExtension))
        let buttons = NSStackView(views: [copy, locate])
        let stack = NSStackView(views: [title, instructions, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        chromeWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ChromeBridge.shared.pairingCode, forType: .string)
        chromeStatus?.stringValue = "连接码已复制，请粘贴到 Chrome 配套扩展中。"
    }
    @objc func revealChromeExtension() {
        let source = Bundle.main.resourceURL!.appendingPathComponent("ChromeExtension")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("QuickGoogleTranslate/ChromeExtension-1.3", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: directory)
            }
            NSWorkspace.shared.open(directory)
        } catch { NSWorkspace.shared.open(source) }
    }
    @objc func configureCloud() {
        let dialog = NSAlert()
        dialog.messageText = "Google Cloud 连接（可选）"
        dialog.informativeText = "默认无需设置。免密钥连接持续失败时，可以使用已启用 Cloud Translation Basic 的 API Key。密钥保存在 macOS 钥匙串，使用量由 Google Cloud 计费。清空并保存可恢复免密钥模式。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "输入 Google Cloud API Key"
        field.stringValue = APIKeyStore.read() ?? ""
        dialog.accessoryView = field
        dialog.addButton(withTitle: "保存")
        dialog.addButton(withTitle: "取消")
        if dialog.runModal() == .alertFirstButtonReturn,
           !APIKeyStore.save(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            alert("未能保存", "macOS 钥匙串未允许保存密钥，请重试。")
        }
    }
    func alert(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
