import AppKit
import SwiftUI

struct BatchAccessFeatureView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: BatchAccessIcon.image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("批量访问")
                VStack(alignment: .leading, spacing: 2) {
                    Text("批量访问").font(.system(size: 22, weight: .semibold))
                    Text("请求管理 · 双向编辑 · 批量执行")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("使用") { BatchAccessWindowLauncher.showWindow() }
                    .buttonStyle(.borderedProminent)
            }
            Text("导入 cURL，编辑 URL、参数和 Body，实时同步请求并查看单次或批量响应。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
        .shadow(color: BatchAccessStyle.accent.opacity(0.10), radius: 18, y: 8)
        .tint(BatchAccessStyle.accent)
    }
}

@MainActor
enum BatchAccessWindowLauncher {
    private static var isLaunching = false
    private static var window: NSWindow?
    private static var windowDelegate: BatchAccessWindowDelegate?
    private static var viewModel: BatchAccessViewModel?

    static func showWindow() {
        guard !isLaunching else { return }
        let applicationURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/KriaBatchAccess.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            showLaunchError("工作台内缺少批量访问组件，请重新编译或安装完整的 KriaWorkbench.app。")
            return
        }
        isLaunching = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            Task { @MainActor in
                isLaunching = false
                if let error { showLaunchError(error.localizedDescription) }
            }
        }
    }

    private static func showLaunchError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法打开批量访问"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // Called only in the embedded component process; the workbench never owns its data.
    static func showLocalWindow() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let viewModel = BatchAccessViewModel()
        let host = NSHostingController(rootView: BatchAccessPanelView(viewModel: viewModel))
        let window = NSWindow(contentViewController: host)
        window.title = "批量访问 · Request Workspace"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KriaBatchAccessWorkspaceWindow")
        window.minSize = NSSize(width: 1120, height: 740)
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.contentView?.autoresizingMask = [.width, .height]
        window.center()
        let delegate = BatchAccessWindowDelegate {
            NSApplication.shared.terminate(nil)
        }
        window.delegate = delegate
        self.windowDelegate = delegate
        self.viewModel = viewModel
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func shutdown() {
        viewModel?.shutdown()
    }

    static func shutdownAndWait() async {
        await viewModel?.shutdownAndWait()
    }
}

@MainActor
private final class BatchAccessWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose; super.init() }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private struct BatchAccessPanelView: View {
    @ObservedObject var viewModel: BatchAccessViewModel
    @State private var isImportPresented = false
    @State private var importText = ""
    @State private var importError: String?
    @State private var requestToDelete: UUID?

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            if let document = viewModel.selectedDocument {
                BatchCurlSplitView {
                    HSplitView {
                        sidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                        BatchRequestResponseSplitView(viewModel: viewModel, document: document)
                            .id(document.id)
                            .frame(minWidth: 520, maxWidth: .infinity)
                    }
                } curl: {
                    curlPanel(document)
                }
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                    emptyWorkspace.frame(minWidth: 800, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let message = viewModel.libraryMessage {
                Divider()
                Text(message).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(BatchAccessStyle.accent)
        .sheet(isPresented: $isImportPresented) { importSheet }
        .alert("删除这个请求？", isPresented: Binding(
            get: { requestToDelete != nil },
            set: { if !$0 { requestToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { requestToDelete = nil }
            Button("删除", role: .destructive) {
                if let id = requestToDelete { viewModel.deleteRequest(id) }
                requestToDelete = nil
            }
        } message: { Text("请求及其响应记录将被移除，正在执行的任务也会停止。") }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: BatchAccessIcon.image)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityLabel("批量访问")
            Text("批量访问").font(.system(size: 15, weight: .semibold))
            Text("/ Request Workspace").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Label("本地自动保存", systemImage: "internaldrive")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button { presentImport() } label: { Label("导入 cURL", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
            Button {
                _ = try? viewModel.addRequest()
            } label: { Label("新建请求", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("请求集合").font(.system(size: 13, weight: .semibold))
                Text("\(viewModel.requests.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { presentImport() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("导入新的 cURL 请求")
            }.padding(14)
            TextField("搜索 URL、名称或方法", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            if viewModel.filteredRequests.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(viewModel.requests.isEmpty ? "还没有请求" : "没有匹配的请求").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.filteredRequests) { document in
                            sidebarRow(document)
                        }
                    }.padding(8)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label("仅保存在本机", systemImage: "lock.shield")
                Text("请求包含的 Cookie / Token 也会保存；不再使用时请删除。")
                    .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private func sidebarRow(_ document: BatchRequestDocument) -> some View {
        Button { viewModel.selectedID = document.id } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(document.request.method).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(BatchAccessStyle.methodColor(document.request.method))
                    .frame(width: 45, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(document.request.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if document.isRunning { ProgressView().controlSize(.mini) }
                else if document.parseError != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(viewModel.selectedID == document.id ? BatchAccessStyle.accent.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("复制请求") { viewModel.duplicateRequest(document.id) }
            Button("删除请求", role: .destructive) { requestToDelete = document.id }
        }
    }

    private func curlPanel(_ document: BatchRequestDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("cURL", systemImage: "terminal").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { viewModel.normalizeCurl(document.id) } label: { Image(systemName: "text.alignleft") }
                    .help("格式化 cURL").disabled(document.parseError != nil)
                Button { BatchAccessStyle.copy(document.curlText) } label: { Image(systemName: "doc.on.doc") }
                    .help("复制 cURL")
            }.buttonStyle(.borderless).padding(14)
            Divider()
            Label("与请求编辑区双向同步", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(12)
            BatchCodeEditor(text: Binding(
                get: { viewModel.requests.first { $0.id == document.id }?.curlText ?? "" },
                set: { viewModel.updateCurl(document.id, value: $0) }
            ))
            .id(document.id)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = document.parseError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("保留上次有效预览；修正后自动同步。发送已禁用。")
                        .foregroundStyle(.secondary)
                } else {
                    Label("请求已同步", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("支持引号、多行命令及常见请求选项。暂不支持文件上传和 Shell 表达式。")
                        .foregroundStyle(.secondary)
                }
                if document.request.allowsInsecureTLS {
                    Label("当前 cURL 关闭了 TLS 证书校验", systemImage: "lock.open.fill").foregroundStyle(.orange)
                }
                if document.isRunning {
                    Text("执行使用发送时快照，编辑内容将在下次发送生效。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 18) {
            Image(systemName: "network").font(.system(size: 52, weight: .light)).foregroundStyle(BatchAccessStyle.accent)
            Text("从一个请求开始").font(.system(size: 23, weight: .semibold))
            Text("导入浏览器或 Postman 中的 cURL，\n在左侧管理请求，中间编辑与查看响应，右侧实时同步命令。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("导入 cURL") { presentImport() }.buttonStyle(.borderedProminent)
                Button("新建空白请求") { _ = try? viewModel.addRequest() }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("导入 cURL 请求", systemImage: "square.and.arrow.down").font(.title3.weight(.semibold))
                Spacer()
                Button { importText = NSPasteboard.general.string(forType: .string) ?? ""; importError = nil }
                label: { Label("从剪贴板粘贴", systemImage: "doc.on.clipboard") }
            }
            Text("粘贴单条 cURL 命令，导入后会生成请求记录。此操作不会发送网络请求。")
                .font(.caption).foregroundStyle(.secondary)
            BatchCodeEditor(text: $importText)
                .frame(height: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if let error = importError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { isImportPresented = false }.keyboardShortcut(.cancelAction)
                Button("导入请求") {
                    do { try viewModel.addRequest(curl: importText); isImportPresented = false }
                    catch { importError = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 660)
    }

    private func presentImport() { importText = ""; importError = nil; isImportPresented = true }
}

/// The secondary cURL editor starts at one sixth of the entire workspace width.
struct BatchCurlSplitView<Main: View, Curl: View>: View {
    @ViewBuilder var main: Main
    @ViewBuilder var curl: Curl
    @State private var curlFraction: CGFloat = 1.0 / 6.0
    @State private var dragStartFraction: CGFloat?
    @Namespace private var splitSpace
    private static var dividerWidth: CGFloat { 7 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let curlWidth = Self.curlWidth(workspaceWidth: width, fraction: curlFraction)
            HStack(spacing: 0) {
                main
                    .frame(width: max(0, width - Self.dividerWidth - curlWidth))
                    .clipped()
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { Divider() }
                    .overlay { Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 30) }
                    .frame(width: Self.dividerWidth)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(splitSpace))
                        .onChanged { value in
                            guard width > 0 else { return }
                            let start = dragStartFraction ?? curlWidth / width
                            dragStartFraction = start
                            curlFraction = Self.curlWidth(workspaceWidth: width,
                                                          fraction: start - value.translation.width / width) / width
                        }
                        .onEnded { _ in dragStartFraction = nil })
                    .accessibilityElement()
                    .accessibilityLabel("调整 cURL 编辑区宽度")
                    .accessibilityValue("cURL \(Int(width > 0 ? curlWidth / width * 100 : 0))%")
                    .accessibilityAdjustableAction { direction in
                        guard width > 0 else { return }
                        let step: CGFloat = direction == .increment ? 0.05 : -0.05
                        curlFraction = Self.curlWidth(workspaceWidth: width,
                                                      fraction: curlWidth / width + step) / width
                    }
                    .help("左右拖动调整 cURL 编辑区宽度")
                curl
                    .frame(width: curlWidth)
                    .clipped()
            }
            .coordinateSpace(name: splitSpace)
        }
    }

    static func curlWidth(workspaceWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        let available = max(0, workspaceWidth - dividerWidth)
        let minimumCurl = min(160, available / 2)
        let minimumMain = min(720, available - minimumCurl)
        return min(max(workspaceWidth * fraction, minimumCurl), available - minimumMain)
    }
}

/// Explicit pane heights prevent long parameter lists from moving the divider.
struct BatchRequestResponseSplitView: View {
    @ObservedObject var viewModel: BatchAccessViewModel
    let document: BatchRequestDocument
    @State private var requestFraction: CGFloat = 0.5
    @State private var dragStartFraction: CGFloat?
    private static let dividerHeight: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(0, geometry.size.height - Self.dividerHeight)
            let requestHeight = Self.requestHeight(availableHeight: availableHeight, fraction: requestFraction)
            VStack(spacing: 0) {
                BatchRequestEditorView(viewModel: viewModel, document: document)
                    .frame(height: requestHeight, alignment: .topLeading)
                    .clipped()
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { Divider() }
                    .overlay { Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 30, height: 3) }
                    .frame(height: Self.dividerHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(document.id))
                        .onChanged { value in
                            guard availableHeight > 0 else { return }
                            let start = dragStartFraction ?? requestHeight / availableHeight
                            dragStartFraction = start
                            requestFraction = Self.requestHeight(
                                availableHeight: availableHeight,
                                fraction: start + value.translation.height / availableHeight
                            ) / availableHeight
                        }
                        .onEnded { _ in dragStartFraction = nil })
                    .accessibilityElement()
                    .accessibilityLabel("调整请求和响应区域比例")
                    .accessibilityValue("请求 \(Int(requestFraction * 100))%，响应 \(Int((1 - requestFraction) * 100))%")
                    .accessibilityAdjustableAction { direction in
                        guard availableHeight > 0 else { return }
                        let step: CGFloat = direction == .increment ? 0.05 : -0.05
                        requestFraction = Self.requestHeight(availableHeight: availableHeight,
                                                             fraction: requestHeight / availableHeight + step) / availableHeight
                    }
                    .help("上下拖动调整请求和响应区域大小")
                BatchResponseView(viewModel: viewModel, document: document)
                    .frame(height: availableHeight - requestHeight, alignment: .topLeading)
                    .clipped()
            }
            .coordinateSpace(name: document.id)
        }
    }

    static func requestHeight(availableHeight: CGFloat, fraction: CGFloat) -> CGFloat {
        let height = max(0, availableHeight)
        // Keep both panes usable; degrade symmetrically for very small windows.
        let minimumRequest = min(300, height / 2)
        let minimumResponse = min(220, height / 2)
        return min(max(height * fraction, minimumRequest), height - minimumResponse)
    }
}

enum BatchAccessStyle {
    static let accent = Color(.sRGB, red: BatchAccessIcon.accentRed,
                              green: BatchAccessIcon.accentGreen, blue: BatchAccessIcon.accentBlue)
    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": .green
        case "POST": .orange
        case "PUT", "PATCH": .blue
        case "DELETE": .red
        default: .purple
        }
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct BatchCodeEditor: View {
    @Binding var text: String
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
