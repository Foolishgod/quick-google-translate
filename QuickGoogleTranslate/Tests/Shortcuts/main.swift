import AppKit
import Carbon

func check(_ value: Bool, _ message: String) {
    precondition(value, message)
    print("PASS: \(message)")
}
final class ClickCounter: NSObject {
    var clicks = 0
    @objc func clicked() { clicks += 1 }
}
final class Checks: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let counter = ClickCounter()
        let recorder = Recorder(title: "Record", target: counter, action: #selector(ClickCounter.clicked))
        recorder.frame = NSRect(x: 20, y: 30, width: 360, height: 30)
        window.contentView!.addSubview(recorder)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            check(self.window.makeFirstResponder(recorder) && self.window.isKeyWindow, "Recorder receives keyboard focus")
            var captures: [Shortcut] = []
            var cancelled = false
            recorder.changed = { captures.append($0) }
            recorder.cancel = { cancelled = true; recorder.recording = false }
            func event(_ flags: NSEvent.ModifierFlags, key: UInt16 = 49, repeated: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, characters: key == 49 ? " " : "\u{1b}", charactersIgnoringModifiers: key == 49 ? " " : "\u{1b}", isARepeat: repeated, keyCode: key)!
            }
            recorder.recording = true
            for flags in [NSEvent.ModifierFlags.control, .option, .command, [.control, .option, .shift, .command]] {
                let count = captures.count
                NSApp.sendEvent(event(flags))
                check(captures.count == count + 1 && captures.last!.key == 49, "AppKit dispatch captures \(Shortcut.space(modifiers: flags).label) exactly once")
                check(captures.last!.matches(Shortcut.space(modifiers: flags)), "Keep modifiers for Space")
            }
            check(counter.clicks == 0, "Space recording must not activate NSButton")
            let count = captures.count
            check(recorder.performKeyEquivalent(with: event(.command)), "Command key-equivalent path is consumed")
            check(captures.count == count + 1 && captures.last!.modifiers == UInt32(cmdKey), "Command key-equivalent path records Space")
            recorder.keyDown(with: event(.option))
            check(captures.count == count + 2, "keyDown fallback records Option Space")
            NSApp.sendEvent(event(.option, repeated: true))
            check(captures.count == count + 2, "Key repeat must not register twice")
            NSApp.sendEvent(event([]))
            NSApp.sendEvent(event(.shift))
            check(captures.count == count + 2 && recorder.recording, "Reject unmodified and Shift-only Space without clicking the button")
            NSApp.sendEvent(event([], key: 53))
            check(cancelled && !recorder.recording, "Escape cancels recording")
            NSApp.sendEvent(event(.option))
            check(captures.count == count + 2, "Recording monitor stops after cancellation")
            recorder.recording = true
            recorder.recording = false
            recorder.recording = true
            NSApp.sendEvent(event(.control))
            check(captures.count == count + 3, "Repeated recording sessions do not accumulate event monitors")
            recorder.recording = false

            recorder.changed = { captures.append($0); recorder.recording = false }
            recorder.recording = true
            NSApp.sendEvent(event(.command))
            check(captures.count == count + 4 && !recorder.recording, "Accepting a shortcut stops recording during event dispatch")
            NSApp.sendEvent(event(.option))
            check(captures.count == count + 4, "Accepted shortcut does not leave an active capture monitor")

            let owner = HotKey(), blocker = HotKey()
            let original = Shortcut.make(key: UInt16(kVK_F18), flags: [.control, .option, .command], characters: nil)!
            let occupied = Shortcut.make(key: UInt16(kVK_F19), flags: [.control, .option, .command], characters: nil)!
            check(owner.register(original), "Register an available global shortcut")
            let reference = owner.reference
            check(owner.register(original) && owner.reference == reference, "Re-selecting active shortcut keeps its registration")
            check(blocker.register(occupied), "Create a controlled registration conflict")
            check(!owner.register(occupied) && owner.reference == reference && owner.registeredShortcut!.matches(original), "Failed replacement preserves the working shortcut")
            blocker.unregister()
            check(owner.register(occupied) && owner.registeredShortcut!.matches(occupied), "Replacement works once conflict is released")
            var normalEvents = 0, englishEvents = 0
            owner.action = { normalEvents += 1 }
            blocker.action = { englishEvents += 1 }
            func send(_ identifier: UInt32) {
                var event: EventRef?
                check(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr, "Create controlled hotkey event")
                var id = EventHotKeyID(signature: 0x51475452, id: identifier)
                check(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr, "Attach independent hotkey identity")
                _ = SendEventToEventTarget(event, GetApplicationEventTarget())
                ReleaseEvent(event)
            }
            send(owner.identifier)
            check(normalEvents == 1 && englishEvents == 0, "Normal hotkey event invokes only its own action")
            send(blocker.identifier)
            check(normalEvents == 1 && englishEvents == 1, "Chinese-to-English hotkey event invokes only its own action")
            check(owner.identifier != blocker.identifier && !Shortcut.standard.matches(.englishStandard), "Independent IDs and distinct default shortcuts")
            owner.unregister()
            for shortcut in Shortcut.spaceChoices {
                let accepted = owner.register(shortcut)
                if shortcut.conflictsWithSystem {
                    check(!accepted && owner.lastFailure == .systemConflict, "Report enabled system conflict for \(shortcut.label)")
                } else if accepted {
                    check(owner.register(shortcut), "Available \(shortcut.label) registers and can be reselected")
                } else {
                    print("INFO: \(shortcut.label) occupied by another running application; system settings unchanged")
                }
                owner.unregister()
            }
            self.window.orderOut(nil)
            print("All native shortcut checks passed. No preferences or system shortcuts changed.")
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let delegate = Checks()
app.delegate = delegate
app.run()
