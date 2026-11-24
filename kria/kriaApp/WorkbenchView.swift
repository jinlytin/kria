import AppKit
import SwiftUI

public struct WorkbenchView: View {
    public init() {}

    public var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("工作台")
                                .font(.system(size: 30, weight: .bold))
                            Text("轻盈、专注的效率工具集合")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .shadow(color: .blue.opacity(0.25), radius: 12)
                    }

                    BatchAccessFeatureView()
                    CustomsFeatureView()
                    RandomClockFeatureView()
                }
                .padding(24)
                .frame(minWidth: 900, alignment: .topLeading)
            }
        }
        .frame(minWidth: 920, minHeight: 720, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                Color(red: 0.78, green: 0.88, blue: 1.0).opacity(0.34)
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .scrollContentBackground(.hidden)
        .background(WorkbenchWindowConfigurator())
    }
}

private struct WorkbenchWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
public enum KriaWorkbenchLauncher {
    private static var workbenchWindow: NSWindow?
    private static var windowDelegate: KriaWorkbenchWindowDelegate?

    public static func showWorkbenchWindow() {
        if let workbenchWindow {
            workbenchWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: WorkbenchView())
        let window = NSWindow(contentViewController: host)
        window.title = "Kria"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KriaWorkbenchWindow")
        window.center()
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor

        let delegate = KriaWorkbenchWindowDelegate {
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

private final class KriaWorkbenchWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
