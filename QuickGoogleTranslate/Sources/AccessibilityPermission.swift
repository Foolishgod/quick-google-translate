import AppKit
import ApplicationServices

struct AccessibilityPermission {
    static func isUsable(systemTrusted: Bool, externalProbe: AXError?) -> Bool {
        // A successful OS-authorized read can confirm access when the trust flag is stale.
        systemTrusted || externalProbe == .success
    }
    static func check() -> Bool {
        if AXIsProcessTrustedWithOptions(nil) { return true }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let target = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.2)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(target, kAXFocusedUIElementAttribute as CFString, &focused)
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return isUsable(systemTrusted: false, externalProbe: result)
    }
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
