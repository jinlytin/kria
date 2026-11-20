import Foundation
import Dispatch
import Darwin

struct CurlExecutionResponse: Sendable {
    var body: String
    var headers: String
    var httpStatus: Int?
    var exitCode: Int32
    var duration: TimeInterval
    var byteCount: Int
    var wasCancelled: Bool
}

enum CurlCommandRunner {
    static let requestTimeout: TimeInterval = 15

    static func run(arguments: [String]) async -> CurlExecutionResponse {
        let state = ExecutionState()
        let startedAt = ProcessInfo.processInfo.systemUptime

        return await withTaskCancellationHandler(operation: {
            // Also cover a task that was cancelled before entering this operation.
            if Task.isCancelled {
                state.cancel()
            }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var response = execute(arguments: arguments, state: state)
                    response.wasCancelled = state.finish()
                    response.duration = ProcessInfo.processInfo.systemUptime - startedAt
                    continuation.resume(returning: response)
                }
            }
        }, onCancel: {
            state.cancel()
        })
    }

    private static func execute(
        arguments: [String], state: ExecutionState
    ) -> CurlExecutionResponse {
        var response = CurlExecutionResponse(
            body: "", headers: "", httpStatus: nil, exitCode: -1,
            duration: 0, byteCount: 0, wasCancelled: false
        )
        guard !state.isCancelled else { return response }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kria-curl-\(UUID().uuidString)", isDirectory: true)
        // Covers failed setup, launch failure, normal completion and cancellation.
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let bodyURL = directory.appendingPathComponent("body")
            let headersURL = directory.appendingPathComponent("headers")
            let stdoutURL = directory.appendingPathComponent("stdout")
            let stderrURL = directory.appendingPathComponent("stderr")

            // Files, not pipes: a verbose response cannot deadlock waiting for a reader.
            for url in [bodyURL, headersURL, stdoutURL, stderrURL] {
                guard FileManager.default.createFile(
                    atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
                ) else {
                    throw RunnerError.fileCreationFailed(url.lastPathComponent)
                }
            }
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            defer { try? stdout.close() }
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderr.close() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--disable", // Must be first to disable the user's curlrc.
                "--proto", "=http,https",
                "--proto-redir", "=http,https"
            ] + arguments + [
                // App-enforced limit cannot be overridden by imported --max-time.
                "--max-time", String(requestTimeout),
                "--silent", "--show-error", "--no-progress-meter",
                "--output", bodyURL.path,
                "--dump-header", headersURL.path,
                "--write-out", "%{http_code}"
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr

            guard try state.start(process) else { return response }
            // This runs exclusively on a background queue, never on the main actor.
            process.waitUntilExit()
            state.processDidExit()
            response.exitCode = state.didTimeOut ? 28 : process.terminationStatus
            response.byteCount = try fileSize(bodyURL)

            let body = try readText(bodyURL, limit: 512 * 1024)
            let headers = try readText(headersURL, limit: 64 * 1024)
            let error = try readText(stderrURL, limit: 64 * 1024)
            let status = try readText(stdoutURL, limit: 1024)
            response.body = body.text
            response.headers = headers.text
            let statusText = status.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if statusText.count == 3,
               statusText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
               let code = Int(statusText), (100...599).contains(code) {
                response.httpStatus = code
            }
            if response.exitCode == 28 {
                append("[请求超时（最长 15 秒），已停止请求]", to: &response.body)
            }
            if response.exitCode != 0 {
                append("[curl 退出码：\(response.exitCode)]", to: &response.body)
                if !error.text.isEmpty {
                    append("[curl stderr]\n\(error.text)", to: &response.body)
                }
            }
            for (name, truncated) in [
                ("body（512 KiB）", body.truncated),
                ("headers（64 KiB）", headers.truncated),
                ("stderr（64 KiB）", error.truncated),
                ("stdout（1 KiB）", status.truncated)
            ] where truncated {
                append("[内容已截断：\(name)]", to: &response.body)
            }
        } catch {
            append("[curl 执行器错误：\(error.localizedDescription)]", to: &response.body)
        }
        return response
    }

    private static func append(_ text: String, to body: inout String) {
        if !body.isEmpty { body += "\n" }
        body += text
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw RunnerError.fileSizeUnavailable
        }
        return size.intValue
    }

    private static func readText(
        _ url: URL, limit: Int
    ) throws -> (text: String, truncated: Bool) {
        let truncated = try fileSize(url) > limit
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count < limit {
            guard let chunk = try handle.read(upToCount: limit - data.count),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, truncated)
        }
        // A byte limit may split the final UTF-8 scalar; do not call that binary.
        if truncated {
            for count in 1...min(3, data.count) {
                if let text = String(data: Data(data.dropLast(count)), encoding: .utf8) {
                    return (text, true)
                }
            }
        }
        return ("[内容不是有效的 UTF-8 文本，可能为二进制数据]", truncated)
    }

    private enum RunnerError: LocalizedError {
        case fileCreationFailed(String)
        case fileSizeUnavailable

        var errorDescription: String? {
            switch self {
            case .fileCreationFailed(let name):
                return "无法创建临时文件：\(name)"
            case .fileSizeUnavailable:
                return "无法获取响应文件大小"
            }
        }
    }

    // All mutable state is protected by lock, including the launch/cancel boundary.
    private final class ExecutionState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var completed = false
        private var timedOut = false
        private var timeoutWorkItem: DispatchWorkItem?
        private var process: Process?

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func start(_ process: Process) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !completed else { return false }
            // Holding the lock through run prevents cancellation from missing a launch.
            try process.run()
            self.process = process
            // --max-time resets per retry; enforce a wall-clock cap for the entire request.
            let timeout = DispatchWorkItem { [weak self] in self?.timeOut() }
            timeoutWorkItem = timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + CurlCommandRunner.requestTimeout, execute: timeout)
            return true
        }

        func processDidExit() {
            lock.lock()
            defer { lock.unlock() }
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
        }

        private func timeOut() {
            lock.lock()
            defer { lock.unlock() }
            guard !completed, !cancelled, let process, process.isRunning else { return }
            timedOut = true
            terminateProcess(process)
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            guard !completed, !cancelled else { return }
            cancelled = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            guard let process = process, process.isRunning else { return }
            terminateProcess(process)
        }

        // Called with lock held so cancellation and timeout cannot race with launch.
        private func terminateProcess(_ process: Process) {
            process.terminate()
            // Ensure cancellation also stops a child that ignores SIGTERM.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                defer { lock.unlock() }
                guard !completed, let running = self.process,
                      running === process, running.isRunning else { return }
                _ = Darwin.kill(running.processIdentifier, SIGKILL)
            }
        }

        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            completed = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            process = nil
            return cancelled
        }
    }
}
