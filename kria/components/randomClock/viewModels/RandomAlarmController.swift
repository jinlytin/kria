import Combine
import Foundation

@MainActor
final class RandomClockViewModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusText = "未开启"
    @Published private(set) var minIntervalMinutes = 3
    @Published private(set) var maxIntervalMinutes = 5

    private var randomClockLoopTask: Task<Void, Never>?
    private let reminderWindowCoordinator = RandomClockReminderWindowCoordinator()
    private let reminderTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    deinit {
        randomClockLoopTask?.cancel()
    }

    func setRandomClockEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        if enabled {
            isEnabled = true
            startRandomClockLoop()
        } else {
            stopRandomClockLoop()
        }
    }

    func setRandomClockMinIntervalMinutes(_ value: Int) {
        let sanitized = min(max(value, 1), 120)
        minIntervalMinutes = min(sanitized, maxIntervalMinutes)
    }

    func setRandomClockMaxIntervalMinutes(_ value: Int) {
        let sanitized = min(max(value, 1), 120)
        maxIntervalMinutes = max(sanitized, minIntervalMinutes)
    }

    private func startRandomClockLoop() {
        randomClockLoopTask?.cancel()

        randomClockLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled, self.isEnabled {
                let minSeconds = self.minIntervalMinutes * 60
                let maxSeconds = self.maxIntervalMinutes * 60
                let delaySeconds = Int.random(in: minSeconds ... maxSeconds)
                let fireTime = Date().addingTimeInterval(TimeInterval(delaySeconds))
                self.statusText = "下一次提醒：\(self.reminderTimeFormatter.string(from: fireTime))"

                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    break
                }

                guard !Task.isCancelled, self.isEnabled else {
                    break
                }

                self.statusText = "提醒中..."
                _ = await self.reminderWindowCoordinator.presentRandomClockReminder(timeout: 10)
                self.statusText = self.isEnabled ? "已关闭提醒，准备下一次随机闹钟..." : "未开启"
            }

            if !self.isEnabled {
                self.statusText = "未开启"
            }
        }
    }

    private func stopRandomClockLoop() {
        isEnabled = false
        randomClockLoopTask?.cancel()
        randomClockLoopTask = nil
        reminderWindowCoordinator.dismissReminderIfNeeded()
        statusText = "未开启"
    }
}
