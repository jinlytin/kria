import Combine
import Foundation

struct BatchRequestDocument: Identifiable {
    var id = UUID()
    var name = ""
    var request = CurlRequest()
    var curlText = ""
    var parseError: String?
    var records: [BatchAccessRecord] = []
    var selectedResponseID: UUID?
    var isRunning = false
    var isStopping = false
    var runID: UUID?
    var status = "等待发送请求"
    var hasError = false
    var requestsPerSecondText = "10"
    var durationText = "3"
    var dispatchMode: BatchDispatchMode = .pulse

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        guard let url = URL(string: request.url), let host = url.host else { return "未命名请求" }
        return host + (url.path.isEmpty || url.path == "/" ? "" : url.path)
    }

    var selectedResponse: BatchAccessRecord? {
        records.first { $0.id == selectedResponseID } ?? records.max { $0.sequence < $1.sequence }
    }
}

@MainActor
final class BatchAccessViewModel: ObservableObject {
    @Published private(set) var requests: [BatchRequestDocument] = []
    @Published var selectedID: UUID?
    @Published var searchText = ""
    @Published private(set) var libraryMessage: String?

    private var executionTasks: [UUID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kria/BatchAccess/requests.json")
        loadRequests()
    }

    var selectedDocument: BatchRequestDocument? { requests.first { $0.id == selectedID } }

    var filteredRequests: [BatchRequestDocument] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? requests : requests.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.request.url.localizedCaseInsensitiveContains(search)
                || $0.request.method.localizedCaseInsensitiveContains(search)
        }
    }

    @discardableResult
    func addRequest(curl: String? = nil) throws -> UUID {
        var document = BatchRequestDocument()
        if let curl {
            document.request = try CurlRequestParser.parse(curl)
            if let components = URLComponents(string: document.request.baseURL) {
                document.name = components.path.isEmpty ? "/" : components.path
            }
            document.curlText = curl
        } else {
            document.request.baseURL = "https://"
            document.curlText = document.request.curl
            document.parseError = "填写 URL 或粘贴完整 cURL 请求后即可发送"
        }
        requests.append(document)
        selectedID = document.id
        searchText = ""
        scheduleSave()
        return document.id
    }

    func duplicateRequest(_ id: UUID) {
        guard let source = requests.first(where: { $0.id == id }) else { return }
        var copy = BatchRequestDocument()
        copy.name = source.displayName + " 副本"
        copy.request = source.request
        copy.curlText = source.curlText
        copy.parseError = source.parseError
        copy.requestsPerSecondText = source.requestsPerSecondText
        copy.durationText = source.durationText
        copy.dispatchMode = source.dispatchMode
        requests.append(copy)
        selectedID = copy.id
        searchText = ""
        scheduleSave()
    }

    func deleteRequest(_ id: UUID) {
        // Keep cancelled tasks tracked until their child processes have exited.
        executionTasks[id]?.cancel()
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests.remove(at: index)
        if selectedID == id { selectedID = requests.isEmpty ? nil : requests[min(index, requests.count - 1)].id }
        scheduleSave()
    }

    func updateDocument<Value>(_ id: UUID, _ keyPath: WritableKeyPath<BatchRequestDocument, Value>, value: Value) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index][keyPath: keyPath] = value
        scheduleSave()
    }

    func updateRequest<Value>(_ id: UUID, _ keyPath: WritableKeyPath<CurlRequest, Value>, value: Value) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].request[keyPath: keyPath] = value
        if keyPath == \CurlRequest.method { requests[index].request.usesCustomMethod = true }
        synchronizeCurl(at: index)
    }

    func updateURL(_ id: UUID, value: String) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].request.setURL(value)
        synchronizeCurl(at: index)
    }

    func updateCurl(_ id: UUID, value: String) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].curlText = value
        do {
            var parsed = try CurlRequestParser.parse(value)
            let previous = requests[index].request
            parsed.query = mergeFields(parsed.query, previous: previous.query)
            parsed.headers = mergeFields(parsed.headers, previous: previous.headers)
            if parsed.bodyMode == .raw, previous.bodyMode == .urlEncoded,
               !parsed.headers.contains(where: { $0.isEnabled && $0.key.lowercased() == "content-type" && !$0.value.lowercased().hasPrefix("application/x-www-form-urlencoded") }) {
                parsed.bodyMode = .urlEncoded
                parsed.bodyFields = CurlRequest.parseQuery(parsed.body, formEncoded: true)
            }
            parsed.bodyFields = mergeFields(parsed.bodyFields, previous: previous.bodyFields)
            requests[index].request = parsed
            requests[index].parseError = nil
        } catch {
            // Never replace the editor's incomplete text or the last valid preview.
            requests[index].parseError = error.localizedDescription
        }
        scheduleSave()
    }

    private func mergeFields(_ parsed: [RequestField], previous: [RequestField]) -> [RequestField] {
        var available = previous.filter(\.isEnabled)
        let active = parsed.map { field -> RequestField in
            var field = field
            if let index = available.firstIndex(where: { $0.key == field.key }) {
                field.id = available.remove(at: index).id
            }
            return field
        }
        return active + previous.filter { !$0.isEnabled }
    }

    func changeBodyMode(_ id: UUID, to mode: RequestBodyMode) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        let oldMode = requests[index].request.bodyMode
        if mode == .urlEncoded, oldMode == .raw {
            requests[index].request.bodyFields = CurlRequest.parseQuery(requests[index].request.body, formEncoded: true)
        } else if mode == .raw, oldMode == .urlEncoded {
            requests[index].request.body = requests[index].request.bodyFields
                .filter { $0.isEnabled && (!$0.key.isEmpty || $0.originalEncodedKey != nil || !$0.value.isEmpty) }.map(\.queryComponent).joined(separator: "&")
        }
        requests[index].request.bodyMode = mode
        if oldMode == .none, mode != .none, requests[index].request.method == "GET" {
            requests[index].request.method = "POST"
        }
        synchronizeCurl(at: index)
    }

    func formatBody(_ id: UUID) {
        guard let document = requests.first(where: { $0.id == id }) else { return }
        updateRequest(id, \.body, value: JSONResponseFormatter.format(document.request.body))
    }

    func normalizeCurl(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].parseError == nil else { return }
        synchronizeCurl(at: index)
    }

    private func synchronizeCurl(at index: Int) {
        requests[index].curlText = requests[index].request.curl
        do {
            try requests[index].request.validate()
            requests[index].parseError = nil
        } catch { requests[index].parseError = error.localizedDescription }
        scheduleSave()
    }

    func start(_ id: UUID, batch: Bool) {
        guard let index = requests.firstIndex(where: { $0.id == id }), !requests[index].isRunning else { return }
        let document = requests[index]
        guard document.parseError == nil else { showError(id, "请先修正 cURL 或请求字段中的错误"); return }
        do { try document.request.validate() } catch { showError(id, error.localizedDescription); return }
        var frequency = 1
        var duration = 1
        if batch {
            guard let rate = Int(document.requestsPerSecondText), (1...1000).contains(rate),
                  let seconds = Int(document.durationText), (1...3600).contains(seconds),
                  rate <= 10_000 / seconds else {
                showError(id, "频率需为 1–1000 次/秒，时长为 1–3600 秒，单批最多 10000 次")
                return
            }
            frequency = rate
            duration = seconds
        }
        let runID = UUID()
        requests[index].records = []
        requests[index].selectedResponseID = nil
        requests[index].isRunning = true
        requests[index].isStopping = false
        requests[index].runID = runID
        requests[index].hasError = false
        requests[index].status = "计划发送 \(frequency * duration) 次 · 最多 32 个并发"
        let arguments = document.request.arguments // Snapshot: edits affect only the next run.
        let mode = document.dispatchMode
        executionTasks[id] = Task { [weak self] in
            await self?.execute(id: id, runID: runID, arguments: arguments, frequency: frequency, duration: duration, mode: mode)
        }
    }

    func stop(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].isRunning else { return }
        requests[index].isStopping = true
        requests[index].status = "正在停止并取消进行中的请求…"
        executionTasks[id]?.cancel()
    }

    func clearRecords(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }), !requests[index].isRunning else { return }
        requests[index].records = []
        requests[index].selectedResponseID = nil
        requests[index].status = "等待发送请求"
        requests[index].hasError = false
    }

    func selectResponse(_ id: UUID, recordID: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].selectedResponseID = recordID
    }

    func shutdown() {
        executionTasks.values.forEach { $0.cancel() }
        executionTasks = [:]
        saveTask?.cancel()
        persistRequests()
    }

    func shutdownAndWait() async {
        let tasks = Array(executionTasks.values)
        shutdown()
        // Allow curl cancellation and the SIGKILL fallback to finish before exiting.
        for task in tasks { await task.value }
    }

    private func execute(id: UUID, runID: UUID, arguments: [String], frequency: Int, duration: Int, mode: BatchDispatchMode) async {
        defer { executionTasks[id] = nil }
        let schedule = (0..<duration).flatMap { second in
            (0..<frequency).map { _ in Double(second) + (mode == .pulse ? 0 : Double.random(in: 0..<1)) }
        }.sorted()
        let clock = ContinuousClock()
        let started = clock.now
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for (sequence, delay) in schedule.enumerated() {
                guard !Task.isCancelled else { break }
                if active >= 32 { await group.next(); active -= 1 }
                do { try await clock.sleep(until: started.advanced(by: .seconds(delay))) }
                catch { break }
                guard !Task.isCancelled else { break }
                active += 1
                group.addTask { [weak self] in
                    guard !Task.isCancelled else { return }
                    await self?.performRequest(id: id, runID: runID, sequence: sequence + 1, arguments: arguments)
                }
            }
            if Task.isCancelled { group.cancelAll() }
        }
        guard let index = requests.firstIndex(where: { $0.id == id && $0.runID == runID }) else { return }
        let failures = requests[index].records.filter(\.isFailure).count
        let completed = requests[index].records.count
        let elapsed = started.duration(to: clock.now).formatted(.units(allowed: [.seconds], width: .abbreviated))
        requests[index].isRunning = false
        requests[index].isStopping = false
        requests[index].hasError = failures > 0
        requests[index].status = Task.isCancelled
            ? "已停止 · 已发起 \(completed) 次"
            : "完成 \(completed) 次 · 失败 \(failures) 次 · \(elapsed)"
    }

    private func performRequest(id: UUID, runID: UUID, sequence: Int, arguments: [String]) async {
        guard !Task.isCancelled,
              let index = requests.firstIndex(where: { $0.id == id && $0.runID == runID }) else { return }
        let recordID = UUID()
        requests[index].records.append(BatchAccessRecord(id: recordID, sequence: sequence, startedAt: Date()))
        let response = await CurlCommandRunner.run(arguments: arguments)
        guard let index = requests.firstIndex(where: { $0.id == id && $0.runID == runID }),
              let recordIndex = requests[index].records.firstIndex(where: { $0.id == recordID }) else { return }
        requests[index].records[recordIndex].finishedAt = Date()
        requests[index].records[recordIndex].result = response.wasCancelled ? "请求已取消" : response.body
        requests[index].records[recordIndex].responseHeaders = response.headers
        requests[index].records[recordIndex].httpStatus = response.httpStatus
        requests[index].records[recordIndex].duration = response.duration
        requests[index].records[recordIndex].byteCount = response.byteCount
        requests[index].records[recordIndex].isFailure = response.wasCancelled || response.exitCode != 0 || !(200...299).contains(response.httpStatus ?? 0)
    }

    private func showError(_ id: UUID, _ message: String) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].hasError = true
        requests[index].status = message
    }

    private struct SavedRequest: Codable {
        var id: UUID
        var name: String
        var request: CurlRequest
        var curlText: String
        var requestsPerSecondText: String?
        var durationText: String?
        var dispatchMode: String?
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.persistRequests()
        }
    }

    private func persistRequests() {
        do {
            let saved = requests.map {
                SavedRequest(id: $0.id, name: $0.name, request: $0.request, curlText: $0.curlText,
                             requestsPerSecondText: $0.requestsPerSecondText, durationText: $0.durationText,
                             dispatchMode: $0.dispatchMode.rawValue)
            }
            let data = try JSONEncoder().encode(saved)
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            libraryMessage = nil
        } catch { libraryMessage = "请求列表保存失败：\(error.localizedDescription)" }
    }

    private func loadRequests() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode([SavedRequest].self, from: Data(contentsOf: storageURL))
            requests = saved.map { value in
                var document = BatchRequestDocument(id: value.id, name: value.name, request: value.request, curlText: value.curlText)
                document.requestsPerSecondText = value.requestsPerSecondText ?? "10"
                document.durationText = value.durationText ?? "3"
                document.dispatchMode = value.dispatchMode.flatMap(BatchDispatchMode.init(rawValue:)) ?? .pulse
                // Validate the saved draft without losing disabled rows in the structured model.
                do { _ = try CurlRequestParser.parse(value.curlText) }
                catch { document.parseError = error.localizedDescription }
                return document
            }
            selectedID = requests.first?.id
        } catch { libraryMessage = "无法读取已保存的请求：\(error.localizedDescription)" }
    }
}
