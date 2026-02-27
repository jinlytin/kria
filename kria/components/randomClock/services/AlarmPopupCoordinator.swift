import AppKit
import SwiftUI

enum ReminderDismissReason {
    case manual
    case timeout
    case forceClosed
}

@MainActor
final class AlarmPopupCoordinator {
    private var popupWindow: NSWindow?
    private var popupDelegate: AlarmPopupWindowDelegate?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<ReminderDismissReason, Never>?
    private var activeSessionID: UUID?

    func presentReminder(timeout: TimeInterval) async -> ReminderDismissReason {
        forceFinishCurrentSession(reason: .forceClosed)

        let sessionID = UUID()
        activeSessionID = sessionID

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let contentView = ReminderPopupView {
                [weak self] in
                self?.completeSession(sessionID: sessionID, reason: .manual)
            }

            let host = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: host)
            window.title = "随机闹钟"
            window.styleMask = [.titled, .closable]
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()

            let delegate = AlarmPopupWindowDelegate { [weak self] in
                self?.completeSession(sessionID: sessionID, reason: .manual)
            }

            popupWindow = window
            popupDelegate = delegate
            window.delegate = delegate

            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await MainActor.run {
                    self?.completeSession(sessionID: sessionID, reason: .timeout)
                }
            }
        }
    }

    func dismissIfNeeded() {
        forceFinishCurrentSession(reason: .forceClosed)
    }

    private func completeSession(sessionID: UUID, reason: ReminderDismissReason) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil

        timeoutTask?.cancel()
        timeoutTask = nil

        if let popupWindow {
            self.popupWindow = nil
            popupDelegate = nil
            popupWindow.delegate = nil
            popupWindow.orderOut(nil)
            popupWindow.close()
        }

        continuation?.resume(returning: reason)
        continuation = nil
    }

    private func forceFinishCurrentSession(reason: ReminderDismissReason) {
        guard activeSessionID != nil else { return }
        let currentSessionID = activeSessionID

        if let currentSessionID {
            completeSession(sessionID: currentSessionID, reason: reason)
        }
    }
}

private final class AlarmPopupWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
