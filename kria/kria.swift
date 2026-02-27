//
//  kria.swift
//  kria
//
//  Created by dingjingli02 on 2026/2/3.
//

import AppKit
import Combine
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
        window.title = "Kria 工作台"
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

private struct RandomAlarmCard: View {
    @ObservedObject var controller: RandomAlarmController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("随机闹钟")
                    .font(.system(size: 22, weight: .semibold))

                Spacer()

                Toggle("", isOn: isEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Text("开启后每隔 \(controller.minIntervalMinutes)～\(controller.maxIntervalMinutes) 分钟弹窗提醒一次。")
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Stepper(
                    value: minMinutesBinding,
                    in: 1 ... 120
                ) {
                    Text("最小：\(controller.minIntervalMinutes) 分钟")
                }

                Stepper(
                    value: maxMinutesBinding,
                    in: 1 ... 120
                ) {
                    Text("最大：\(controller.maxIntervalMinutes) 分钟")
                }
            }

            Text(controller.statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var minMinutesBinding: Binding<Int> {
        Binding(
            get: { controller.minIntervalMinutes },
            set: { controller.setMinIntervalMinutes($0) }
        )
    }

    private var maxMinutesBinding: Binding<Int> {
        Binding(
            get: { controller.maxIntervalMinutes },
            set: { controller.setMaxIntervalMinutes($0) }
        )
    }
}

@MainActor
final class RandomAlarmController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusText = "未开启"
    @Published private(set) var minIntervalMinutes = 3
    @Published private(set) var maxIntervalMinutes = 5

    private var schedulerTask: Task<Void, Never>?
    private let popupCoordinator = AlarmPopupCoordinator()
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    deinit {
        schedulerTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        if enabled {
            isEnabled = true
            startSchedulerLoop()
        } else {
            stopSchedulerLoop()
        }
    }

    func setMinIntervalMinutes(_ value: Int) {
        let sanitized = min(max(value, 1), 120)
        minIntervalMinutes = min(sanitized, maxIntervalMinutes)
    }

    func setMaxIntervalMinutes(_ value: Int) {
        let sanitized = min(max(value, 1), 120)
        maxIntervalMinutes = max(sanitized, minIntervalMinutes)
    }

    private func startSchedulerLoop() {
        schedulerTask?.cancel()

        schedulerTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled, self.isEnabled {
                let minSeconds = self.minIntervalMinutes * 60
                let maxSeconds = self.maxIntervalMinutes * 60
                let delaySeconds = Int.random(in: minSeconds ... maxSeconds)
                let fireTime = Date().addingTimeInterval(TimeInterval(delaySeconds))
                self.statusText = "下一次提醒：\(self.timeFormatter.string(from: fireTime))"

                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    break
                }

                guard !Task.isCancelled, self.isEnabled else {
                    break
                }

                self.statusText = "提醒中..."
                _ = await self.popupCoordinator.presentReminder(timeout: 10)
                self.statusText = self.isEnabled ? "已关闭提醒，准备下一次随机闹钟..." : "未开启"
            }

            if !self.isEnabled {
                self.statusText = "未开启"
            }
        }
    }

    private func stopSchedulerLoop() {
        isEnabled = false
        schedulerTask?.cancel()
        schedulerTask = nil
        popupCoordinator.dismissIfNeeded()
        statusText = "未开启"
    }
}

private enum ReminderDismissReason {
    case manual
    case timeout
    case forceClosed
}

@MainActor
private final class AlarmPopupCoordinator {
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

private struct ReminderPopupView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时间到了，活动一下")
                .font(.system(size: 18, weight: .semibold))

            Text("10 秒后自动关闭并开始下一次随机提醒。")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button("关闭并进入下一次提醒") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
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
