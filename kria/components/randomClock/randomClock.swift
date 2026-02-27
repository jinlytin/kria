import AppKit
import SwiftUI

public struct WorkbenchView: View {
    @StateObject private var randomAlarm = RandomAlarmController()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("工作台")
                .font(.system(size: 30, weight: .bold))

            RandomAlarmCard(controller: randomAlarm)
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 380, alignment: .topLeading)
    }
}

@MainActor
public enum KriaWorkbenchLauncher {
    private static var workbenchWindow: NSWindow?
    private static var windowDelegate: WorkbenchWindowDelegate?

    public static func showWorkbenchWindow() {
        if let workbenchWindow {
            workbenchWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: WorkbenchView())
        let window = NSWindow(contentViewController: host)
        window.title = "Kria"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KriaWorkbenchWindow")
        window.center()

        let delegate = WorkbenchWindowDelegate {
            workbenchWindow = nil
            windowDelegate = nil
        }
        window.delegate = delegate

        self.windowDelegate = delegate
        self.workbenchWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public static func closeWorkbenchWindow() {
        guard let workbenchWindow else { return }
        self.workbenchWindow = nil
        windowDelegate = nil
        workbenchWindow.delegate = nil
        workbenchWindow.close()
    }
}

private final class WorkbenchWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
