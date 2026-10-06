import AppKit
import Carbon

struct Shortcut {
    var key: UInt32
    var modifiers: UInt32
    var label: String
    static let standard = space(modifiers: .option)
    static let spaceChoices = [space(modifiers: .control), space(modifiers: .option), space(modifiers: .command)]

    static func space(modifiers: NSEvent.ModifierFlags) -> Shortcut {
        make(key: 49, flags: modifiers, characters: " ")!
    }
    static func make(key: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Shortcut? {
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        var mask: UInt32 = 0
        var label = ""
        for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) {
            mask |= UInt32(carbon)
            label += symbol
        }
        let names: [UInt16: String] = [49: "空格", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let name = names[key] ?? characters?.uppercased() ?? "Key \(key)"
        return Shortcut(key: UInt32(key), modifiers: mask, label: label + " " + name)
    }
    func matches(_ other: Shortcut) -> Bool { key == other.key && modifiers == other.modifiers }
    static var saved: Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: "shortcutKey") != nil else { return .standard }
        return Shortcut(key: UInt32(d.integer(forKey: "shortcutKey")), modifiers: UInt32(d.integer(forKey: "shortcutModifiers")), label: d.string(forKey: "shortcutLabel") ?? standard.label)
    }
    func save() {
        let d = UserDefaults.standard
        d.set(Int(key), forKey: "shortcutKey")
        d.set(Int(modifiers), forKey: "shortcutModifiers")
        d.set(label, forKey: "shortcutLabel")
    }
    var conflictsWithSystem: Bool {
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr, let entries = values?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true &&
            (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == key &&
            (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == modifiers
        }
    }
}

final class HotKey {
    enum Failure {
        case systemConflict, unavailable
        var message: String {
            switch self {
            case .systemConflict: return "此组合被系统占用。请到“系统设置 → 键盘 → 键盘快捷键”，更改 Spotlight 或输入法等对应快捷键后再选择。"
            case .unavailable: return "此组合无法注册，可能被其他应用占用。请更改该应用的快捷键，或选择其他组合。"
            }
        }
    }
    private(set) var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registeredShortcut: Shortcut?
    private(set) var lastFailure: Failure?
    var action: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) -> Bool {
        lastFailure = nil
        guard !shortcut.conflictsWithSystem else { lastFailure = .systemConflict; return false }
        // Re-selecting the active combination must not collide with our own registration.
        if reference != nil, registeredShortcut?.matches(shortcut) == true { return true }
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: 0x51475452, id: 1), GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr else { lastFailure = .unavailable; return false }
        unregister()
        reference = candidate
        registeredShortcut = shortcut
        return true
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        registeredShortcut = nil
    }
    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}

final class Recorder: NSButton {
    private var monitor: Any?
    var recording = false {
        didSet {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard recording else { return }
            // Capture before AppKit routes Command shortcuts or treats Space as a button click.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording, event.window === self.window,
                      self.window?.isKeyWindow == true, self.window?.firstResponder === self else { return event }
                self.capture(event)
                return nil
            }
        }
    }
    var changed: ((Shortcut) -> Void)?
    var cancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        capture(event)
    }
    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { cancel?(); return }
        guard let shortcut = Shortcut.make(key: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers) else {
            title = "请包含 ⌘、⌃ 或 ⌥"; return
        }
        changed?(shortcut)
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
