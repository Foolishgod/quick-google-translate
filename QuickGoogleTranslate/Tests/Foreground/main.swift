import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "翻译浮窗前台测试 · 临时窗口"
window.contentView = NSTextField(labelWithString: "独立前台窗口，用于检查翻译浮窗的实际显示顺序。")
window.center()
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { app.terminate(nil) }
app.run()
