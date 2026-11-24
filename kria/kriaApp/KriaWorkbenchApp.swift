import AppKit
import SwiftUI

#if CUSTOMS_APP
@main
@MainActor
enum KriaCustomsApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = CustomsApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
#elseif BATCH_ACCESS_APP
@main
@MainActor
enum KriaBatchAccessApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = BatchAccessApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class BatchAccessApplicationDelegate: NSObject, NSApplicationDelegate {
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        NSApplication.shared.applicationIconImage = BatchAccessIcon.image
        BatchAccessWindowLauncher.showLocalWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        BatchAccessWindowLauncher.showLocalWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isTerminating {
            isTerminating = true
            Task { @MainActor in
                await BatchAccessWindowLauncher.shutdownAndWait()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        BatchAccessWindowLauncher.shutdown()
    }

    private func installMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Kria 批量访问")
        applicationMenu.addItem(withTitle: "隐藏批量访问", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出批量访问", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                     ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.windowsMenu = windowMenu
    }
}
#else
@main
struct KriaWorkbenchApp: App {
    var body: some Scene {
        WindowGroup("Kria 工作台") {
            WorkbenchView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
#endif
