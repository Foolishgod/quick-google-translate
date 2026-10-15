import AppKit

// AppKit can return -1 for Preview even while WindowServer exposes its real PID.
// Resolve once and use the same identity for permission checks, AX, copy events,
// foreground checks and activation notifications.
struct SelectionApplication {
    let application: NSRunningApplication
    let pid: pid_t

    static func selectPID(reported: pid_t, windowOwners: [pid_t], matches: (pid_t) -> Bool) -> pid_t? {
        if reported > 0 { return reported }
        var seen = Set<pid_t>()
        return windowOwners.first { $0 > 0 && seen.insert($0).inserted && matches($0) }
    }

    init?(_ application: NSRunningApplication) {
        let reported = application.processIdentifier
        if reported > 0 {
            self.application = application; pid = reported; return
        }
        guard let expectedURL = application.bundleURL?.standardizedFileURL else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owners = windows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
        guard let resolved = Self.selectPID(reported: reported, windowOwners: owners, matches: { candidate in
            // Match the application identity, not a localized window title or
            // process name. Never use an unrelated foreground window as fallback.
            NSRunningApplication(processIdentifier: candidate)?.bundleURL?.standardizedFileURL == expectedURL
        }) else { return nil }
        self.application = application; pid = resolved
    }

    static var frontmost: SelectionApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap { SelectionApplication($0) }
    }

    var isFrontmost: Bool { Self.frontmost?.pid == pid }
}
