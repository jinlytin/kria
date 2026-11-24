import AppKit
import SwiftUI

struct CustomsFeatureView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: CustomsIcon.image).resizable().scaledToFit().frame(width: 44, height: 44)
                    .accessibilityLabel("海关")
                VStack(alignment: .leading, spacing: 2) {
                    Text("海关").font(.system(size: 22, weight: .semibold))
                    Text("网络代理 · 实时抓包 · Header 改写").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("使用") { CustomsWindowLauncher.showWindow() }.buttonStyle(.borderedProminent)
            }
            Text("检查 App 的请求与响应，复制为 cURL，使用 swimlane 等规则改写请求头。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
        .shadow(color: .cyan.opacity(0.10), radius: 18, y: 8)
        .tint(Color(red: 0.10, green: 0.48, blue: 0.62))
    }
}

@MainActor
enum CustomsWindowLauncher {
    private static var launching = false
    private static var window: NSWindow?
    private static var delegate: CustomsWindowDelegate?
    private static var viewModel: CustomsViewModel?

    static func showWindow() {
        guard !launching else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KriaCustoms.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("工作台内缺少海关组件，请重新编译或安装完整的 KriaWorkbench.app。"); return
        }
        launching = true
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false; config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            Task { @MainActor in
                launching = false
                if let error { showError(error.localizedDescription) }
            }
        }
    }
    private static func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "无法打开海关"; alert.informativeText = message
        alert.alertStyle = .warning; alert.addButton(withTitle: "好"); alert.runModal()
    }
    static func showLocalWindow() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return
        }
        let model = CustomsViewModel()
        let host = NSHostingController(rootView: CustomsWorkspaceView(vm: model))
        let window = NSWindow(contentViewController: host)
        window.title = "海关 · Network Proxy"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KriaCustomsWorkspaceWindow")
        window.minSize = NSSize(width: 1120, height: 780)
        window.setContentSize(NSSize(width: 1440, height: 920))
        window.center()
        let delegate = CustomsWindowDelegate()
        window.delegate = delegate
        self.delegate = delegate; self.window = window; self.viewModel = model
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    static func shutdown() { viewModel?.shutdown() }
}

@MainActor
private final class CustomsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}

#if CUSTOMS_APP
@MainActor
final class CustomsApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        NSApplication.shared.applicationIconImage = CustomsIcon.image
        CustomsWindowLauncher.showLocalWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        CustomsWindowLauncher.showLocalWindow(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CustomsWindowLauncher.shutdown(); return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { CustomsWindowLauncher.shutdown() }
    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(title: "Kria 海关")
        appMenu.addItem(withTitle: "隐藏海关", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出海关", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; menu.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"),
                                     ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu; menu.addItem(edit)
        let item = NSMenuItem(); let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.submenu = windowMenu; menu.addItem(item)
        NSApplication.shared.mainMenu = menu; NSApplication.shared.windowsMenu = windowMenu
    }
}
#endif
