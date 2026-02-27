import SwiftUI

struct RandomAlarmCard: View {
    @ObservedObject var controller: RandomAlarmController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.16, green: 0.42, blue: 0.88), Color(red: 0.21, green: 0.67, blue: 0.89)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)

                        Image(systemName: "alarm.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("随机闹钟")
                            .font(.system(size: 22, weight: .semibold))

                        Text("专注节奏提醒")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: isEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                Label("区间", systemImage: "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())

                Text("\(controller.minIntervalMinutes)～\(controller.maxIntervalMinutes) 分钟")
                    .font(.system(size: 13, weight: .semibold))
            }

            HStack(spacing: 16) {
                Stepper(value: minMinutesBinding, in: 1 ... 120) {
                    Text("最小：\(controller.minIntervalMinutes) 分钟")
                }

                Stepper(value: maxMinutesBinding, in: 1 ... 120) {
                    Text("最大：\(controller.maxIntervalMinutes) 分钟")
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isEnabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                Text(controller.statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
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

struct ReminderPopupView: View {
    let onDismiss: () -> Void
    @State private var shouldSwing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()

                Image(systemName: "alarm.fill")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.98, green: 0.54, blue: 0.18), Color(red: 0.98, green: 0.36, blue: 0.19)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .rotationEffect(.degrees(shouldSwing ? 14 : -14))
                    .offset(x: shouldSwing ? 10 : -10)
                    .animation(
                        .easeInOut(duration: 0.18).repeatForever(autoreverses: true),
                        value: shouldSwing
                    )
                    .onAppear {
                        shouldSwing = true
                    }

                Spacer()
            }

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
        .frame(width: 400)
    }
}
