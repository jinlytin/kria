import Combine
import Foundation

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
