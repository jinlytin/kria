import AppKit
import SwiftUI

enum RandomClockReminderDismissReason {
    case manualDismiss
    case timeoutAutoDismiss
    case forceClosedBySystem
}

@MainActor
final class RandomClockReminderWindowCoordinator {
    private var reminderWindow: NSWindow?
    private var reminderWindowDelegate: RandomClockReminderWindowDelegate?
    private var autoDismissTask: Task<Void, Never>?
    private var dismissContinuation: CheckedContinuation<RandomClockReminderDismissReason, Never>?
    private var activeReminderSessionID: UUID?

    func presentRandomClockReminder(timeout: TimeInterval) async -> RandomClockReminderDismissReason {
        forceCompleteCurrentReminderSession(reason: .forceClosedBySystem)

        let sessionID = UUID()
        activeReminderSessionID = sessionID

        return await withCheckedContinuation { continuation in
            self.dismissContinuation = continuation

            let contentView = RandomClockReminderPopupView {
                [weak self] in
                self?.completeReminderSession(sessionID: sessionID, reason: .manualDismiss)
            }

            let host = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: host)
            window.title = "随机闹钟"
            window.styleMask = [.titled, .closable]
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()

            let delegate = RandomClockReminderWindowDelegate { [weak self] in
                self?.completeReminderSession(sessionID: sessionID, reason: .manualDismiss)
            }

            reminderWindow = window
            reminderWindowDelegate = delegate
            window.delegate = delegate

            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)

            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await MainActor.run {
                    self?.completeReminderSession(sessionID: sessionID, reason: .timeoutAutoDismiss)
                }
            }
        }
    }

    func dismissReminderIfNeeded() {
        forceCompleteCurrentReminderSession(reason: .forceClosedBySystem)
    }

    private func completeReminderSession(sessionID: UUID, reason: RandomClockReminderDismissReason) {
        guard activeReminderSessionID == sessionID else { return }
        activeReminderSessionID = nil

        autoDismissTask?.cancel()
        autoDismissTask = nil

        if let reminderWindow {
            self.reminderWindow = nil
            reminderWindowDelegate = nil
            reminderWindow.delegate = nil
            reminderWindow.orderOut(nil)
            reminderWindow.close()
        }

        dismissContinuation?.resume(returning: reason)
        dismissContinuation = nil
    }

    private func forceCompleteCurrentReminderSession(reason: RandomClockReminderDismissReason) {
        guard activeReminderSessionID != nil else { return }
        let currentSessionID = activeReminderSessionID

        if let currentSessionID {
            completeReminderSession(sessionID: currentSessionID, reason: reason)
        }
    }
}

private final class RandomClockReminderWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
