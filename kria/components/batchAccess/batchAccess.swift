import AppKit
import Combine
import Foundation
import SwiftUI

struct BatchAccessFeatureView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.43, green: 0.22, blue: 0.82), Color(red: 0.79, green: 0.31, blue: 0.74)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("批量访问")
                        .font(.system(size: 22, weight: .semibold))
                    Text("按设定频率并发执行 curl 请求")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("使用") {
                    BatchAccessWindowLauncher.showWindow()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("配置请求频率、输入 curl 命令，并在独立窗口中查看每次调用的响应结果。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.blue.opacity(0.10), radius: 18, y: 8)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
private enum BatchAccessWindowLauncher {
    private static var window: NSWindow?
    private static var windowDelegate: BatchAccessWindowDelegate?

    static func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: BatchAccessPanelView())
        let window = NSWindow(contentViewController: host)
        window.title = "批量访问"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KriaBatchAccessWindow")
        window.minSize = NSSize(width: 960, height: 700)
        window.setContentSize(NSSize(width: 960, height: 700))
        window.contentView?.autoresizingMask = [.width, .height]
        window.center()

        let delegate = BatchAccessWindowDelegate {
            self.window = nil
            self.windowDelegate = nil
        }
        window.delegate = delegate
        self.windowDelegate = delegate
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private final class BatchAccessWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct BatchAccessPanelView: View {
    @StateObject private var viewModel = BatchAccessViewModel()
    @State private var expandedRecordIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            configuration
            curlInput
            resultTable
        }
        .padding(20)
        .frame(minWidth: 920, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity, alignment: .leading)
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

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.43, green: 0.22, blue: 0.82), Color(red: 0.79, green: 0.31, blue: 0.74)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("批量访问")
                    .font(.system(size: 22, weight: .semibold))
                Text("按设定频率并发执行 curl 请求")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isRunning {
                Button("停止") {
                    viewModel.stop()
                }
                .buttonStyle(.bordered)
            }

        }
    }

    private var configuration: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("每秒访问次数")
                    .font(.system(size: 13, weight: .medium))
                TextField("10", text: $viewModel.requestsPerSecondText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("持续访问秒数")
                    .font(.system(size: 13, weight: .medium))
                TextField("3", text: $viewModel.durationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("访问方式")
                    .font(.system(size: 13, weight: .medium))
                Picker("访问方式", selection: $viewModel.dispatchMode) {
                    ForEach(BatchDispatchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .horizontalRadioGroupLayout()
            }

            Spacer(minLength: 8)

            Button(viewModel.isRunning ? "执行中…" : "确认执行") {
                viewModel.start()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var curlInput: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Curl 命令")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("仅支持以 curl 开头的单条命令")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $viewModel.curlCommand)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 100)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var resultTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("请求结果")
                    .font(.system(size: 15, weight: .semibold))
                Text(viewModel.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.hasError ? .red : .secondary)
                Spacer()
                if !viewModel.records.isEmpty {
                    Button("清空结果") {
                        viewModel.clearRecords()
                    }
                    .buttonStyle(.link)
                }
            }

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    BatchAccessResultHeader()

                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.records) { record in
                                BatchAccessResultRow(
                                    record: record,
                                    isExpanded: expandedRecordIDs.contains(record.id)
                                ) {
                                    toggleExpansion(for: record.id)
                                }
                            }
                        }
                        .frame(minWidth: 900, alignment: .leading)
                    }
                    .frame(minHeight: 220, maxHeight: .infinity)
                }
                .frame(minWidth: 900, maxHeight: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func toggleExpansion(for recordID: UUID) {
        if expandedRecordIDs.contains(recordID) {
            expandedRecordIDs.remove(recordID)
        } else {
            expandedRecordIDs.insert(recordID)
        }
    }
}

private struct BatchAccessResultHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            tableCell("序号", width: 60)
            tableCell("开始时间", width: 160)
            tableCell("结束时间", width: 160)
            tableCell("状态", width: 80)
            tableCell("响应结果（点击展开 JSON）", width: 440)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tableCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
    }
}

private struct BatchAccessResultRow: View {
    let record: BatchAccessRecord
    let isExpanded: Bool
    let onToggleExpansion: () -> Void

    private var formattedResponse: String {
        JSONResponseFormatter.format(record.result)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                Text("\(record.sequence)")
                    .frame(width: 60, alignment: .leading)
                Text(record.startedAt.formatted(date: .omitted, time: .standard))
                    .frame(width: 160, alignment: .leading)
                Text(record.finishedAt?.formatted(date: .omitted, time: .standard) ?? "请求中…")
                    .frame(width: 160, alignment: .leading)
                Text(record.httpStatus.map(String.init) ?? (record.finishedAt == nil ? "请求中" : "—"))
                    .frame(width: 80, alignment: .leading)
                    .foregroundStyle(record.isFailure ? .red : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onToggleExpansion) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(record.result)
                            .lineLimit(isExpanded ? nil : 1)
                            .truncationMode(.tail)
                    }
                    .frame(width: 440, alignment: .leading)
                    .foregroundStyle(record.isFailure ? .red : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                if isExpanded {
                    Text(formattedResponse)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(width: 420, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(record.isFailure ? Color.red.opacity(0.7) : Color.accentColor.opacity(0.7))
                                .frame(width: 3)
                        }
                }
            }
            .padding(.trailing, 10)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(record.sequence.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor).opacity(0.45) : .clear)
    }
}

private enum JSONResponseFormatter {
    static func format(_ response: String) -> String {
        guard let data = response.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(jsonObject),
              let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
              let prettyResponse = String(data: prettyData, encoding: .utf8) else {
            return response
        }
        return prettyResponse
    }
}

private enum BatchDispatchMode: String, CaseIterable, Identifiable {
    case pulse
    case randomWithinSecond

    var id: Self { self }

    var title: String {
        switch self {
        case .pulse: "脉冲"
        case .randomWithinSecond: "每秒内随机"
        }
    }
}

private struct BatchAccessRecord: Identifiable {
    let id: UUID
    let sequence: Int
    let startedAt: Date
    var finishedAt: Date?
    var result: String
    var httpStatus: Int?
    var isFailure: Bool
}

@MainActor
private final class BatchAccessViewModel: ObservableObject {
    @Published var requestsPerSecondText = "10"
    @Published var durationText = "3"
    @Published var dispatchMode: BatchDispatchMode = .pulse
    @Published var curlCommand = ""
    @Published private(set) var records: [BatchAccessRecord] = []
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "等待执行"
    @Published private(set) var hasError = false

    private var executionTask: Task<Void, Never>?

    func start() {
        guard let requestsPerSecond = Int(requestsPerSecondText), requestsPerSecond > 0,
              let duration = Int(durationText), duration > 0 else {
            showError("访问次数和持续秒数必须为正整数")
            return
        }

        let command = curlCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command == "curl" || command.hasPrefix("curl ") else {
            showError("请输入以 curl 开头的命令")
            return
        }

        records = []
        isRunning = true
        hasError = false
        statusText = "计划执行 \(requestsPerSecond * duration) 次请求"

        executionTask = Task { [weak self] in
            guard let self else { return }
            await self.execute(
                command: command,
                requestsPerSecond: requestsPerSecond,
                duration: duration,
                mode: dispatchMode
            )
        }
    }

    func stop() {
        executionTask?.cancel()
        executionTask = nil
        isRunning = false
        statusText = "已停止，已发起 \(records.count) 次请求"
    }

    func clearRecords() {
        guard !isRunning else { return }
        records = []
        statusText = "等待执行"
        hasError = false
    }

    private func execute(command: String, requestsPerSecond: Int, duration: Int, mode: BatchDispatchMode) async {
        let totalRequests = requestsPerSecond * duration
        let schedule = makeSchedule(requestsPerSecond: requestsPerSecond, duration: duration, mode: mode)
        let launchTime = ContinuousClock.now

        await withTaskGroup(of: Void.self) { group in
            for (index, delay) in schedule.enumerated() {
                group.addTask { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }

                    guard !Task.isCancelled else { return }
                    await self?.performRequest(sequence: index + 1, command: command)
                }
            }
        }

        guard !Task.isCancelled else { return }
        let elapsed = launchTime.duration(to: .now).formatted(.units(allowed: [.seconds], width: .abbreviated))
        isRunning = false
        statusText = "已完成 \(totalRequests) 次请求，耗时 \(elapsed)"
        executionTask = nil
    }

    private func performRequest(sequence: Int, command: String) async {
        let startedAt = Date()
        let recordID = UUID()
        records.append(
            BatchAccessRecord(
                id: recordID,
                sequence: sequence,
                startedAt: startedAt,
                finishedAt: nil,
                result: "请求中…",
                httpStatus: nil,
                isFailure: false
            )
        )

        let response = await CurlCommandRunner.run(command)
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].finishedAt = Date()
        records[index].result = response.body
        records[index].httpStatus = response.httpStatus
        records[index].isFailure = response.exitCode != 0 || !(200...299).contains(response.httpStatus ?? 0)
    }

    private func makeSchedule(requestsPerSecond: Int, duration: Int, mode: BatchDispatchMode) -> [Double] {
        (0..<duration).flatMap { second in
            switch mode {
            case .pulse:
                Array(repeating: Double(second), count: requestsPerSecond)
            case .randomWithinSecond:
                (0..<requestsPerSecond).map { _ in Double(second) + Double.random(in: 0..<1) }
            }
        }
    }

    private func showError(_ message: String) {
        hasError = true
        statusText = message
    }
}

private enum CurlCommandRunner {
    private static let statusMarker = "__KRIA_HTTP_STATUS__:"

    static func run(_ command: String) async -> (exitCode: Int32, body: String, httpStatus: Int?) {
        let commandWithStatus = command + " --silent --show-error --write-out '\n__KRIA_HTTP_STATUS__:%{http_code}\n'"

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", commandWithStatus]
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                do {
                    try process.run()
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let rawOutput = String(data: data, encoding: .utf8) ?? "无法读取响应内容"
                    let response = parseResponse(rawOutput)
                    continuation.resume(returning: (process.terminationStatus, response.body, response.httpStatus))
                } catch {
                    continuation.resume(returning: (-1, "执行失败：\(error.localizedDescription)", nil))
                }
            }
        }
    }

    private static func parseResponse(_ output: String) -> (body: String, httpStatus: Int?) {
        guard let markerRange = output.range(of: statusMarker, options: .backwards) else {
            let body = String(output.prefix(512_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            return (body.isEmpty ? "未获得响应内容（curl 未输出 HTTP 状态）" : body, nil)
        }

        let body = String(output[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusText = output[markerRange.upperBound...].split(whereSeparator: \.isNewline).first.map(String.init)
        return (body.isEmpty ? "完成（无响应体）" : String(body.prefix(512_000)), statusText.flatMap(Int.init))
    }
}
