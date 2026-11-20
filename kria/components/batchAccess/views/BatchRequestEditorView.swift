import SwiftUI

private enum RequestEditorTab: String, CaseIterable {
    case params = "Params", headers = "Headers", body = "Body", settings = "设置"
}

struct BatchRequestEditorView: View {
    @ObservedObject var viewModel: BatchAccessViewModel
    let document: BatchRequestDocument
    @State private var tab: RequestEditorTab = .params
    @State private var urlDraft = ""
    @FocusState private var isURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            urlBar
            batchConfiguration
            Divider()
            tabBar
            Divider()
            tabContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { urlDraft = document.request.url }
        .onChange(of: document.id) { _, _ in urlDraft = document.request.url }
        .onChange(of: document.request.url) { _, value in
            // Own keystrokes already updated the draft; external cURL/Params edits
            // must still refresh the URL even if this field retains focus.
            if urlDraft != value { urlDraft = value }
        }
        .onChange(of: isURLFocused) { _, focused in
            if !focused { urlDraft = document.request.url }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            TextField(document.displayName, text: documentBinding(\.name))
                .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                .help("编辑请求名称")
            Spacer()
            Text("REQUEST").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                TextField("GET", text: requestBinding(\.method))
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(BatchAccessStyle.methodColor(document.request.method))
                    .frame(width: 58)
                Menu {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { method in
                        Button(method) { viewModel.updateRequest(document.id, \.method, value: method) }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).fixedSize().frame(width: 16)
                Divider().frame(height: 22)
                TextField("https://api.example.com/path", text: Binding(
                    get: { urlDraft },
                    set: { urlDraft = $0; viewModel.updateURL(document.id, value: $0) }
                ))
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .focused($isURLFocused)
                .onSubmit { viewModel.start(document.id, batch: false) }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if document.isRunning {
                Button(document.isStopping ? "停止中…" : "停止") { viewModel.stop(document.id) }
                    .buttonStyle(.bordered).disabled(document.isStopping)
            } else {
                Button { viewModel.start(document.id, batch: false) } label: {
                    Label("发送", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(document.parseError != nil)
            }
        }.padding(.horizontal, 14).padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 20) {
            ForEach(RequestEditorTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                        if let count = count(for: item), count > 0 {
                            Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                    .foregroundStyle(tab == item ? Color.primary : .secondary)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        if tab == item { Rectangle().fill(BatchAccessStyle.accent).frame(height: 2) }
                    }
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .params:
            BatchFieldsEditor(fields: requestBinding(\.query), title: "Query Params", keyPlaceholder: "参数名", valuePlaceholder: "参数值")
        case .headers:
            BatchFieldsEditor(fields: requestBinding(\.headers), title: "Request Headers", keyPlaceholder: "Header", valuePlaceholder: "Value")
        case .body:
            bodyEditor
        case .settings:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("跟随重定向（--location）", isOn: requestBinding(\.followsRedirects))
                    Toggle("接受压缩响应（--compressed）", isOn: requestBinding(\.compressed))
                    Toggle("忽略 TLS 证书校验（--insecure）", isOn: requestBinding(\.allowsInsecureTLS))
                    if document.request.allowsInsecureTLS {
                        Text("注意：已关闭证书校验，仅用于可信测试环境。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("每次请求最多 15 秒（包含重试等待），超时自动停止；协议仅允许 HTTP / HTTPS。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !document.request.extraArguments.isEmpty {
                        Text("保留的其他 cURL 参数").font(.caption.weight(.semibold))
                        Text(document.request.extraArguments.map(CurlRequest.quote).joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Text("可在右侧 cURL 区编辑这些参数。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Body 类型", selection: Binding(
                    get: { document.request.bodyMode },
                    set: { viewModel.changeBodyMode(document.id, to: $0) }
                )) {
                    ForEach(RequestBodyMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.labelsHidden().frame(width: 220)
                Spacer()
                if document.request.bodyMode == .raw {
                    Button("格式化 JSON") { viewModel.formatBody(document.id) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
            switch document.request.bodyMode {
            case .none:
                VStack(spacing: 8) {
                    Image(systemName: "doc").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("这个请求没有 Body").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .raw:
                BatchCodeEditor(text: requestBinding(\.body))
                Text("Raw 按原文发送；JSON 请在 Headers 中设置 Content-Type: application/json。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 6)
            case .urlEncoded, .multipart:
                BatchFieldsEditor(fields: requestBinding(\.bodyFields), title: "Body 字段（仅文本）", keyPlaceholder: "字段名", valuePlaceholder: "字段值")
            }
        }
    }

    private var batchConfiguration: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("批量执行", systemImage: "square.stack.3d.up").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("次/秒").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("10", text: documentBinding(\.requestsPerSecondText)).textFieldStyle(.roundedBorder).frame(width: 48)
                Text("秒").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("3", text: documentBinding(\.durationText)).textFieldStyle(.roundedBorder).frame(width: 48)
                Picker("调度方式", selection: documentBinding(\.dispatchMode)) {
                    ForEach(BatchDispatchMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.labelsHidden().frame(width: 110)
                Button("执行") { viewModel.start(document.id, batch: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(document.isRunning || document.parseError != nil)
            }.controlSize(.small)
            HStack(spacing: 6) {
                if document.isRunning { ProgressView().controlSize(.mini) }
                Text(document.status).font(.system(size: 10))
                    .foregroundStyle(document.hasError ? Color.red : .secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func count(for tab: RequestEditorTab) -> Int? {
        switch tab {
        case .params: document.request.query.filter { $0.isEnabled && !$0.key.isEmpty }.count
        case .headers: document.request.headers.filter { $0.isEnabled && !$0.key.isEmpty }.count
        default: nil
        }
    }

    private func requestBinding<Value>(_ keyPath: WritableKeyPath<CurlRequest, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.requests.first { $0.id == document.id }?.request[keyPath: keyPath] ?? document.request[keyPath: keyPath] },
            set: { viewModel.updateRequest(document.id, keyPath, value: $0) }
        )
    }

    private func documentBinding<Value>(_ keyPath: WritableKeyPath<BatchRequestDocument, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.requests.first { $0.id == document.id }?[keyPath: keyPath] ?? document[keyPath: keyPath] },
            set: { viewModel.updateDocument(document.id, keyPath, value: $0) }
        )
    }
}

private struct BatchFieldsEditor: View {
    @Binding var fields: [RequestField]
    let title: String
    let keyPlaceholder: String
    let valuePlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { fields.append(RequestField()) } label: { Label("添加字段", systemImage: "plus") }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }.padding(.horizontal, 14).padding(.vertical, 10)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($fields) { $field in
                        HStack(spacing: 8) {
                            Toggle("启用", isOn: $field.isEnabled).labelsHidden().toggleStyle(.checkbox)
                            TextField(keyPlaceholder, text: $field.key).textFieldStyle(.roundedBorder)
                                .frame(minWidth: 100)
                            TextField(valuePlaceholder, text: $field.value).textFieldStyle(.roundedBorder)
                                .frame(minWidth: 160)
                            Button { fields.removeAll { $0.id == field.id } } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }.buttonStyle(.plain).help("删除字段")
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .opacity(field.isEnabled ? 1 : 0.5)
                    }
                    if fields.isEmpty {
                        Text("暂无字段，点击“添加字段”开始编辑。")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }
        }
    }
}
