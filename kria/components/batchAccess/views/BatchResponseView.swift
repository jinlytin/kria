import SwiftUI

private enum ResponseTab: String, CaseIterable {
    case body = "Body", headers = "Headers", history = "批量记录"
}

struct BatchResponseView: View {
    @ObservedObject var viewModel: BatchAccessViewModel
    let document: BatchRequestDocument
    @State private var tab: ResponseTab = .body
    @State private var pretty = true
    @State private var jsonDocument: JSONResponseDocument?
    @State private var jsonRows: [JSONResponseRow] = []
    @State private var collapsedNodeIDs: Set<Int> = []
    @State private var preparedSource: ResponseSource?

    private var currentSource: ResponseSource {
        ResponseSource(recordID: document.selectedResponse?.id, text: document.selectedResponse?.result ?? "")
    }

    private var activeJSONDocument: JSONResponseDocument? {
        preparedSource == currentSource ? jsonDocument : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("响应").font(.system(size: 13, weight: .semibold))
                if let record = document.selectedResponse {
                    if let status = record.httpStatus {
                        Text("\(status)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(record.isFailure ? .red : .green)
                    } else {
                        Text(record.finishedAt == nil ? "请求中…" : "未获得 HTTP 状态")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if record.finishedAt != nil {
                        Text(String(format: "%.0f ms", record.duration * 1000))
                        Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                    }
                }
                Spacer()
                if !document.records.isEmpty {
                    Text("\(document.records.count) 次").font(.caption).foregroundStyle(.secondary)
                    Button { viewModel.clearRecords(document.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("清空当前请求的响应")
                        .disabled(document.isRunning)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            HStack(spacing: 16) {
                ForEach(ResponseTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? Color.primary : .secondary)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if tab == item { Rectangle().fill(BatchAccessStyle.accent).frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if tab == .body, pretty, let jsonDocument = activeJSONDocument, !jsonDocument.expandableNodeIDs.isEmpty {
                    Menu {
                        Button("展开全部") { setCollapsedNodes([]) }
                        Button("折叠全部") { setCollapsedNodes(jsonDocument.expandableNodeIDs) }
                        Button("仅展开两层") {
                            setCollapsedNodes(Set(jsonDocument.rows(collapsedNodeIDs: [])
                                .filter { $0.isExpandable && !$0.isClosing && $0.depth >= 2 }.map(\.nodeID)))
                        }
                    } label: { Label("展开/折叠", systemImage: "list.bullet.indent") }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .fixedSize()
                    .help("JSON 节点展开与折叠；也可点击左侧行号旁的箭头")
                }
                if tab == .body {
                    Picker("响应格式", selection: $pretty) {
                        Text("Pretty").tag(true)
                        Text("Raw").tag(false)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 112).controlSize(.mini)
                }
                if let record = document.selectedResponse, tab != .history {
                    Button { BatchAccessStyle.copy(responseText(record)) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("复制响应内容")
                }
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            Divider()
            if tab == .history {
                history
            } else if let record = document.selectedResponse {
                ResponseTextEditor(
                    text: tab == .headers ? responseText(record) : (record.result.isEmpty ? "（无响应体）" : record.result),
                    jsonRows: tab == .body && pretty && activeJSONDocument != nil ? jsonRows : [],
                    isFailure: record.isFailure && tab == .body,
                    onToggleNode: toggleNode,
                    onCopyNode: copyNode
                )
                .id(ResponseEditorIdentity(recordID: record.id, tab: tab, pretty: pretty))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityLabel(tab == .headers ? "响应头，只读，可选择和复制" : "响应内容，只读，可选择和复制")
                Divider()
                HStack(spacing: 6) {
                    Text("#\(record.sequence) · \(record.startedAt.formatted(date: .omitted, time: .standard))")
                    Text("→ \(record.finishedAt?.formatted(date: .omitted, time: .standard) ?? "请求中")")
                    Spacer()
                    if document.selectedResponseID != nil {
                        Button("最新响应") {
                            viewModel.updateDocument(document.id, \.selectedResponseID, value: nil)
                        }.buttonStyle(.borderless)
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("发送请求后，响应会显示在这里").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("状态码、耗时、响应头及每次批量调用的结果")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: currentSource) {
            let source = currentSource
            preparedSource = nil
            jsonDocument = nil
            jsonRows = []
            collapsedNodeIDs = []
            // Build the bounded tree away from the main actor; discard obsolete results.
            let preparation = await Task.detached(priority: .userInitiated) {
                guard let parsed = JSONResponseDocument.parse(source.text) else { return nil as PreparedResponseJSON? }
                let allRows = parsed.rows(collapsedNodeIDs: [])
                let collapsed = Set(allRows.filter { $0.isExpandable && !$0.isClosing && $0.depth >= 2 }.map(\.nodeID))
                return PreparedResponseJSON(document: parsed, rows: parsed.rows(collapsedNodeIDs: collapsed), collapsed: collapsed)
            }.value
            guard !Task.isCancelled, let preparation else { return }
            preparedSource = source
            jsonDocument = preparation.document
            collapsedNodeIDs = preparation.collapsed
            jsonRows = preparation.rows
        }
    }

    private func setCollapsedNodes(_ ids: Set<Int>) {
        collapsedNodeIDs = ids
        jsonRows = jsonDocument?.rows(collapsedNodeIDs: ids) ?? []
    }

    private func toggleNode(_ id: Int) {
        var ids = collapsedNodeIDs
        if !ids.insert(id).inserted { ids.remove(id) }
        setCollapsedNodes(ids)
    }

    private func copyNode(_ id: Int) {
        guard let jsonDocument = activeJSONDocument else { return }
        var pending = [jsonDocument.root]
        while let node = pending.popLast() {
            if node.id == id { BatchAccessStyle.copy(node.rawValue); return }
            pending.append(contentsOf: node.children)
        }
    }

    private func responseText(_ record: BatchAccessRecord) -> String {
        if tab == .headers { return record.responseHeaders.isEmpty ? "暂无响应头" : record.responseHeaders }
        if record.result.isEmpty { return "（无响应体）" }
        // Copy always includes hidden children and never changes number precision.
        guard pretty, let jsonDocument = activeJSONDocument else { return record.result }
        return jsonDocument.rows(collapsedNodeIDs: []).map { row in
            String(repeating: "  ", count: row.depth) + (row.key.map { $0 + ": " } ?? "")
                + row.value + (row.hasComma ? "," : "")
        }.joined(separator: "\n")
    }

    private struct ResponseSource: Equatable {
        let recordID: UUID?
        let text: String
    }

    private struct ResponseEditorIdentity: Hashable {
        let recordID: UUID
        let tab: ResponseTab
        let pretty: Bool
    }

    private struct PreparedResponseJSON: Sendable {
        let document: JSONResponseDocument
        let rows: [JSONResponseRow]
        let collapsed: Set<Int>
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("序号").frame(width: 40, alignment: .leading)
                Text("开始时间").frame(width: 75, alignment: .leading)
                Text("状态").frame(width: 60, alignment: .leading)
                Text("耗时").frame(width: 65, alignment: .leading)
                Text("响应预览").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(document.records.sorted { $0.sequence < $1.sequence }) { record in
                        Button {
                            viewModel.selectResponse(document.id, recordID: record.id)
                            tab = .body
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(record.sequence)").frame(width: 32, alignment: .leading)
                                Text(record.startedAt.formatted(date: .omitted, time: .standard))
                                    .frame(width: 67, alignment: .leading)
                                Text(record.httpStatus.map(String.init) ?? (record.finishedAt == nil ? "…" : "失败"))
                                    .foregroundStyle(record.isFailure ? .red : .green)
                                    .frame(width: 52, alignment: .leading)
                                Text(record.finishedAt == nil ? "…" : String(format: "%.0f ms", record.duration * 1000))
                                    .frame(width: 57, alignment: .leading)
                                Text(record.result.isEmpty ? "（无响应体）" : record.result)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .background(record.sequence.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : .clear)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("点击记录查看完整响应；每次执行只保留本轮结果。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
}
