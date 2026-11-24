import SwiftUI

private enum RandomClockStyle {
    static let accent = Color(red: 0.28, green: 0.62, blue: 0.85)
}

struct RandomClockCardView: View {
    @ObservedObject var randomClockViewModel: RandomClockViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RandomClockStyle.accent, in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("随机闹钟")

                VStack(alignment: .leading, spacing: 2) {
                    Text("随机闹钟")
                        .font(.system(size: 22, weight: .semibold))
                    Text("随机间隔 · 专注提醒 · 自动关闭")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("开启提醒", isOn: isEnabledBinding)
                    .font(.system(size: 12, weight: .medium))
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            HStack(spacing: 16) {
                configurationView
                statusView
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
        .shadow(color: RandomClockStyle.accent.opacity(0.10), radius: 18, y: 8)
        .tint(RandomClockStyle.accent)
    }

    private var configurationView: some View {
        HStack(spacing: 12) {
            Label("提醒区间", systemImage: "timer")
                .foregroundStyle(.secondary)
                .fixedSize()

            Stepper(value: minMinutesBinding, in: 1 ... 120) {
                Text("最小：\(randomClockViewModel.minIntervalMinutes) 分钟")
                    .monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: false)

            Stepper(value: maxMinutesBinding, in: 1 ... 120) {
                Text("最大：\(randomClockViewModel.maxIntervalMinutes) 分钟")
                    .monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .help("支持 1～120 分钟，区间调整将在下一轮提醒生效。")
    }

    private var statusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(randomClockViewModel.isEnabled ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(randomClockViewModel.statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(randomClockViewModel.isEnabled ? Color.primary : Color.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { randomClockViewModel.isEnabled },
            set: { randomClockViewModel.setRandomClockEnabled($0) }
        )
    }

    private var minMinutesBinding: Binding<Int> {
        Binding(
            get: { randomClockViewModel.minIntervalMinutes },
            set: { randomClockViewModel.setRandomClockMinIntervalMinutes($0) }
        )
    }

    private var maxMinutesBinding: Binding<Int> {
        Binding(
            get: { randomClockViewModel.maxIntervalMinutes },
            set: { randomClockViewModel.setRandomClockMaxIntervalMinutes($0) }
        )
    }
}

struct RandomClockReminderPopupView: View {
    let onConfirmDismiss: () -> Void
    @State private var shouldSwing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()

                Image(systemName: "alarm.fill")
                    .font(.system(size: 108, weight: .bold))
                    .foregroundStyle(RandomClockStyle.accent)
                    .rotationEffect(.degrees(shouldSwing ? 14 : -14))
                    .offset(x: shouldSwing ? 20 : -20)
                    .animation(
                        .easeInOut(duration: 0.18).repeatForever(autoreverses: true),
                        value: shouldSwing
                    )
                    .onAppear {
                        shouldSwing = true
                    }

                Spacer()
            }

            Text("Mind Break!")
                .font(.system(size: 18, weight: .semibold))

            Text("10 秒后自动关闭并开始下一次随机提醒。")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button("关闭并进入下一次提醒") {
                    onConfirmDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .tint(RandomClockStyle.accent)
    }
}
