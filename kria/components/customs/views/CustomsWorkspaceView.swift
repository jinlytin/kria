import AppKit
import SwiftUI

/// The owner supplies the single proxy view model and owns its shutdown lifecycle.
@MainActor
struct CustomsWorkspaceView: View {
    @ObservedObject var vm: CustomsViewModel
    @State private var sheet: CustomsWorkspaceSheet?
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 URL、域名、路径、Method 或状态", text: $vm.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索抓包记录")
                    .help("与左侧请求树检索叠加筛选；支持 URL、Method、状态和错误信息")
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索")
                }
                if !vm.searchText.isEmpty || !vm.treeSearchText.isEmpty || vm.selectedHost != nil {
                    Button("清除全部筛选", action: vm.resetRequestFilters)
                        .help("清除两个搜索框和节点选择；保留抓包记录")
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
            if !vm.decryptHTTPS && vm.transactions.contains(where: { $0.isTunnel && $0.method == "CONNECT" }) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                    Text("HTTPS 解密未开启：CONNECT 只记录隧道连接，不显示其中的真实请求与响应。")
                    Spacer(minLength: 0)
                    Button("HTTPS 设置") { sheet = .settings }
                        .help("停止代理后开启 HTTPS 解密；手机还需完全信任 CA，再重新发起请求")
                }
                .font(.caption).foregroundStyle(.orange)
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                CustomsHostList(vm: vm)
                    .frame(minWidth: 210, idealWidth: 260, maxWidth: 380)
                VSplitView {
                    CustomsTransactionTable(vm: vm)
                        .frame(minHeight: 160, idealHeight: 290)
                    CustomsTransactionDetail(transaction: vm.selectedTransaction, vm: vm)
                        .frame(minHeight: 230, idealHeight: 340)
                }
                .frame(minWidth: 530)
            }
            statusBar
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $sheet) { item in
            switch item {
            case .settings: CustomsConfigurationSheet(vm: vm)
            case .rules: CustomsRulesSheet(vm: vm)
            case .help: CustomsCertificateHelpView(vm: vm)
            case .certificate: CustomsCertificateView(vm: vm)
            }
        }
        .alert("清空所有抓包记录？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) { vm.clear() }
        } message: {
            Text("将移除当前内存中的请求、响应和选中记录。不会停止代理，也不会删除规则或配置。此操作无法撤销。")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Image(nsImage: CustomsIcon.image)
                .resizable().scaledToFit().frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("海关").font(.headline)
                Text("HTTP 调试代理").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 26)
            Button(action: vm.toggleProxy) {
                Label(vm.isStarting ? "启动中…" : (vm.isRunning ? "停止代理" : "启动代理"),
                      systemImage: vm.isRunning ? "stop.fill" : "play.fill")
            }
            .disabled(vm.isStarting)
            .help("启停本地代理；不会自动设置系统网络代理")
            Button(action: vm.toggleRecording) {
                Label(vm.isRecording ? "暂停录制" : "继续录制",
                      systemImage: vm.isRecording ? "pause.circle" : "record.circle")
            }
            .help("只暂停新增记录，代理和改写仍继续工作")
            Button { confirmingClear = true } label: {
                Image(systemName: "trash")
            }
            .disabled(vm.transactions.isEmpty)
            .help("清空内存记录")
            Toggle("改写", isOn: $vm.rewriteEnabled)
                .toggleStyle(.switch).fixedSize()
                .onChange(of: vm.rewriteEnabled) { _, _ in vm.saveRules() }
                .help("启用已保存的 Header 规则，对后续请求实时生效")
            Spacer(minLength: 0)
            Menu {
                Button("复制改写后请求 cURL") { vm.copyCurl() }
                Button("复制原始请求 cURL") { vm.copyCurl(original: true) }
            } label: {
                Label("cURL", systemImage: "doc.on.doc")
            }
            .disabled(vm.selectedTransaction?.canCopyCurl != true)
            .help("仅完整且成功结束的 HTTP 请求可复制；CONNECT 隧道、截断、失败及进行中的请求不可完整重放")
            Button { sheet = .rules } label: { Image(systemName: "slider.horizontal.3") }
                .help("编辑 Header 改写规则")
            Button { sheet = .certificate } label: {
                Image(systemName: "checkmark.shield")
            }
            .help("证书管理：本机信任与手机配置")
            Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                .help("代理与 HTTPS 设置")
            Button { sheet = .help } label: { Image(systemName: "questionmark.circle") }
                .help("连接设备与信任证书指南")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(vm.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(vm.isStarting ? "正在启动" : (vm.isRunning ? "代理运行中" : "代理已停止"))
                Divider().frame(height: 12)
                Text(vm.isRecording ? "录制中" : "录制已暂停 · 代理继续转发")
                Spacer()
                Text("显示 \(vm.filteredTransactions.count) / \(vm.transactions.count) 条 · 最多 1000 条 / 总正文 64 MiB")
            }
            HStack(spacing: 8) {
                Label("本机代理", systemImage: "desktopcomputer")
                Text("服务器：127.0.0.1")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("端口：\(vm.portText)").monospacedDigit().textSelection(.enabled)
                Button(action: vm.copyEndpoint) { Label("复制地址", systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).help("复制 \(vm.endpoint)；填写 HTTP / HTTPS 代理时，服务器和端口分别填写，不加 http://")
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 8) {
                Label("手机 / 局域网", systemImage: "iphone")
                if vm.localProxyAddresses.isEmpty {
                    Text("未检测到局域网 IPv4 地址，请连接 Wi-Fi 或有线网络后刷新。")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(vm.localProxyAddresses, id: \.self) { address in
                                Button { vm.copyProxyAddress(address) } label: {
                                    Label(address, systemImage: "doc.on.doc")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .buttonStyle(.plain)
                                .help("点击复制服务器:端口；手机与 Mac 需在同一网络，选择手机可访问的网卡地址，不要填写 127.0.0.1")
                                .accessibilityLabel("局域网代理地址 \(address)，点击复制")
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 20)
                }
                Button(action: vm.refreshProxyAddresses) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新网卡地址（切换 Wi-Fi 或 VPN 后使用）")
                    .accessibilityLabel("刷新代理地址")
            }
            Text(vm.listenOnLAN
                 ? "局域网地址按「服务器:端口」展示，请分开填写。手机需与 Mac 在同一网络；启动代理后生效。"
                 : "当前仅允许本机连接。手机使用前，请在代理设置中开启「允许局域网连接」，再启动代理；手机不要填写 127.0.0.1。")
                .foregroundStyle(vm.listenOnLAN ? Color.secondary : Color.orange)
            if let message = vm.message, !message.isEmpty {
                Text(message).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("请求 / 响应每侧正文最多预览 512 KiB；最多保留 1000 条，总正文预算 64 MiB，超出时可提早淘汰旧记录。抓包内容仅驻留内存，不保存正文。规则与配置会持久化，请勿在规则中保存令牌等敏感信息。")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .onAppear { vm.refreshProxyAddresses() }
    }
}

private enum CustomsWorkspaceSheet: String, Identifiable {
    case settings, rules, help, certificate
    var id: String { rawValue }
}

@MainActor
private struct CustomsHostList: View {
    @ObservedObject var vm: CustomsViewModel
    @State private var expandedHosts: Set<String> = []
    @State private var expandedPaths: Set<CustomsRequestTreeNode.ID> = []
    @State private var collapsedSearchNodes: Set<CustomsRequestTreeNode.ID> = []
    @FocusState private var searchFocused: Bool

    private var nodes: [CustomsRequestTreeNode] { vm.requestTreeNodes }
    private var filtering: Bool {
        vm.isTreeSearching || !vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CustomsPaneHeading(title: "结构视图", subtitle: "域名 → 路径 → 请求", symbol: "folder")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("检索域名、路径、URL", text: $vm.treeSearchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("请求树检索")
                    .help("按域名、路径、查询参数或完整 URL 包含匹配，不区分大小写；支持中文编码 URL")
                    .onExitCommand { vm.treeSearchText = "" }
                if !vm.treeSearchText.isEmpty {
                    Button { vm.treeSearchText = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("清除请求树检索")
                    .accessibilityLabel("清除请求树检索")
                }
            }
            .font(.callout).padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            .padding(.horizontal, 10).padding(.top, 10)
            HStack(spacing: 6) {
                Text("\(nodes.count) 个域名 · \(vm.treeFilteredTransactions.count) 条请求")
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button { searchFocused = true } label: { Image(systemName: "text.magnifyingglass") }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: [.command, .option])
                    .help("检索请求树（⌥⌘F）").accessibilityLabel("聚焦请求树检索")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Button { vm.selectTreeNode(host: nil) } label: {
                HStack {
                    Label(filtering ? "全部检索结果" : "全部域名", systemImage: "network")
                    Spacer()
                    if vm.selectedHost == nil { Image(systemName: "checkmark") }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 8)
            List {
                ForEach(nodes) { node in
                    DisclosureGroup(isExpanded: expansion(for: node.id)) {
                        ForEach(node.children ?? []) { path in
                            DisclosureGroup(isExpanded: expansion(for: path.id)) {
                                ForEach(path.children ?? []) { leaf in
                                    if let transaction = leaf.transaction { transactionButton(transaction) }
                                }
                            } label: {
                                nodeButton(path)
                            }
                        }
                    } label: {
                        nodeButton(node)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if nodes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: vm.transactions.isEmpty ? "network" : "magnifyingglass")
                            .font(.title2).foregroundStyle(.secondary)
                        Text(vm.transactions.isEmpty ? "尚无抓包记录" : "没有匹配的域名或路径")
                            .font(.callout.weight(.medium))
                        Text(vm.transactions.isEmpty ? "启动代理并配置客户端后，\n请求将出现在这里。" : "调整左侧检索词或顶部搜索条件。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if filtering { Button("清除全部筛选", action: vm.resetRequestFilters) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
                }
            }
            Divider()
            if let host = vm.selectedHost {
                HStack(alignment: .top) {
                    Text("已选：\(host)\(vm.selectedPath ?? "")")
                        .lineLimit(2).help(host + (vm.selectedPath ?? ""))
                    Spacer(minLength: 0)
                    Button { vm.selectTreeNode(host: nil) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).help("取消节点选择，保留检索词")
                        .accessibilityLabel("取消请求树节点选择")
                }
                .font(.caption).padding(.horizontal, 12).padding(.top, 8)
            }
            Text("同域名按 path 分组（不含查询参数），路径默认折叠；展开后逐条查看，请求不会合并。")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .onChange(of: vm.treeSearchText) { _, _ in collapsedSearchNodes.removeAll() }
        .onChange(of: vm.searchText) { _, _ in collapsedSearchNodes.removeAll() }
        .onChange(of: vm.transactions.map(\.id)) { _, _ in
            let hosts = Set(vm.hosts)
            expandedHosts.formIntersection(hosts)
            let paths = Set(vm.transactions.map { CustomsRequestTreeNode.ID(host: $0.host, path: $0.groupingPath) })
            expandedPaths.formIntersection(paths)
            collapsedSearchNodes = collapsedSearchNodes.filter {
                $0.path == nil ? hosts.contains($0.host) : paths.contains($0)
            }
        }
        .onChange(of: vm.selectedID) { _, _ in revealSelection() }
        .onAppear { revealSelection() }
    }

    private func expansion(for id: CustomsRequestTreeNode.ID) -> Binding<Bool> {
        Binding(get: {
            if filtering { return !collapsedSearchNodes.contains(id) }
            return id.path == nil ? expandedHosts.contains(id.host) : expandedPaths.contains(id)
        }, set: { expanded in
            if filtering {
                if expanded { collapsedSearchNodes.remove(id) } else { collapsedSearchNodes.insert(id) }
            } else if id.path == nil {
                if expanded { expandedHosts.insert(id.host) } else { expandedHosts.remove(id.host) }
            } else {
                if expanded { expandedPaths.insert(id) } else { expandedPaths.remove(id) }
            }
        })
    }

    private func revealSelection() {
        // Automatic first-row selection must not expand a newly captured path.
        guard vm.selectedPath != nil, let transaction = vm.selectedTransaction else { return }
        let hostID = CustomsRequestTreeNode.ID(host: transaction.host, path: nil)
        let pathID = CustomsRequestTreeNode.ID(host: transaction.host, path: transaction.groupingPath)
        expandedHosts.insert(transaction.host)
        expandedPaths.insert(pathID)
        collapsedSearchNodes.remove(hostID); collapsedSearchNodes.remove(pathID)
    }

    private func transactionButton(_ transaction: CustomsTransaction) -> some View {
        let selected = vm.selectedID == transaction.id
        return Button { vm.selectTreeTransaction(id: transaction.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: transaction.isTunnel ? "lock.shield" : "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                    Text(transaction.method).font(.system(.caption, design: .monospaced).weight(.semibold))
                    Spacer(minLength: 0)
                    Text(CustomsDisplay.status(transaction)).foregroundStyle(CustomsDisplay.statusColor(transaction))
                    if selected { Image(systemName: "checkmark") }
                }
                if transaction.path != transaction.groupingPath {
                    Text(transaction.path).lineLimit(1).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Text(transaction.startedAt, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(transaction.isTunnel ? "加密隧道" : CustomsDisplay.size(transaction.responseByteCount))
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption).padding(.vertical, 5).padding(.horizontal, 5)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(transaction.method) \(transaction.url)\n\(transaction.startedAt.formatted(date: .numeric, time: .standard))\n\(transaction.error ?? CustomsDisplay.status(transaction))")
        .accessibilityLabel("\(transaction.method)，\(transaction.url)，\(CustomsDisplay.status(transaction))")
        .accessibilityValue(selected ? "已选中" : "未选中")
        .contextMenu {
            Button("复制改写后请求 cURL") { vm.selectTreeTransaction(id: transaction.id); vm.copyCurl() }
                .disabled(!transaction.canCopyCurl)
            Button("复制原始请求 cURL") { vm.selectTreeTransaction(id: transaction.id); vm.copyCurl(original: true) }
                .disabled(!transaction.canCopyCurl)
        }
    }

    private func nodeButton(_ node: CustomsRequestTreeNode) -> some View {
        let selected = vm.selectedHost == node.host && vm.selectedPath == node.path
        return Button {
            vm.selectTreeNode(host: node.host, path: node.path)
            expansion(for: node.id).wrappedValue = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.path == nil ? "globe" : "doc").foregroundStyle(.secondary)
                highlighted(node.path ?? node.host).lineLimit(1).help(node.path ?? node.host)
                Spacer(minLength: 2)
                Text("\(node.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if selected { Image(systemName: "checkmark").font(.caption) }
            }
            .padding(.vertical, 3).contentShape(Rectangle())
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.path ?? node.host)，\(node.count) 条请求")
        .accessibilityValue(selected ? "已选中" : "未选中")
    }

    private func highlighted(_ value: String) -> Text {
        let query = vm.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(value) }
        var content = AttributedString(value)
        var remaining = value.startIndex..<value.endIndex
        while let range = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining, locale: .current) {
            if let lower = AttributedString.Index(range.lowerBound, within: content),
               let upper = AttributedString.Index(range.upperBound, within: content) {
                content[lower..<upper].font = .callout.bold()
                content[lower..<upper].foregroundColor = .accentColor
            }
            remaining = range.upperBound..<value.endIndex
        }
        return Text(content)
    }
}

private struct CustomsPaneHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            Spacer()
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

@MainActor
private struct CustomsTransactionTable: View {
    @ObservedObject var vm: CustomsViewModel

    var body: some View {
        VStack(spacing: 0) {
            CustomsPaneHeading(title: "序列视图", subtitle: "请求按捕获顺序显示", symbol: "list.bullet")
            Table(vm.filteredTransactions, selection: $vm.selectedID) {
                TableColumn("URL") { transaction in
                    HStack(spacing: 6) {
                        Image(systemName: transaction.isTunnel ? "lock.shield" : "arrow.up.arrow.down")
                            .foregroundStyle(.secondary)
                        Text(transaction.url).lineLimit(1).help(transaction.url)
                    }
                }
                .width(min: 200, ideal: 400)
                TableColumn("Method") { transaction in
                    Text(transaction.method).font(.system(.caption, design: .monospaced))
                }
                .width(68)
                TableColumn("状态") { transaction in
                    Text(CustomsDisplay.status(transaction))
                        .foregroundStyle(CustomsDisplay.statusColor(transaction))
                        .help(transaction.error ?? CustomsDisplay.status(transaction))
                }
                .width(98)
                TableColumn("耗时") { transaction in
                    Text(CustomsDisplay.duration(transaction)).monospacedDigit()
                }
                .width(82)
                TableColumn("响应大小") { transaction in
                    Text(CustomsDisplay.size(transaction.responseByteCount)).monospacedDigit()
                }
                .width(86)
            }
            .font(.caption)
            .contextMenu(forSelectionType: UUID.self) { ids in
                let id = ids.count == 1 ? ids.first : nil
                let canCopy = id.flatMap { selected in vm.transactions.first { $0.id == selected } }?.canCopyCurl == true
                Button("复制改写后请求 cURL") { copy(id: id, original: false) }
                    .disabled(!canCopy)
                Button("复制原始请求 cURL") { copy(id: id, original: true) }
                    .disabled(!canCopy)
            }
            .overlay {
                if vm.filteredTransactions.isEmpty {
                    ContentUnavailableView {
                        Label(vm.transactions.isEmpty ? "尚无抓包记录" : "没有匹配的请求", systemImage: "network")
                    } description: {
                        Text(vm.transactions.isEmpty ? "启动代理、保持录制，并让客户端使用此代理。" : "调整左侧请求树检索、顶部搜索或节点选择。")
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func copy(id: UUID?, original: Bool) {
        guard let id, vm.transactions.first(where: { $0.id == id })?.canCopyCurl == true else { return }
        vm.selectedID = id
        vm.copyCurl(original: original)
    }
}

private enum CustomsDetailTab: String, CaseIterable {
    case overview = "概要", request = "请求", response = "响应"
}

private struct CustomsTransactionDetail: View {
    let transaction: CustomsTransaction?
    @ObservedObject var vm: CustomsViewModel
    @State private var tab: CustomsDetailTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("详情", systemImage: "doc.text.magnifyingglass").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("详情类型", selection: $tab) {
                    ForEach(CustomsDetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 230)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let transaction {
                switch tab {
                case .overview: CustomsOverview(transaction: transaction)
                case .request: CustomsMessageDetail(transaction: transaction, isResponse: false, vm: vm)
                case .response: CustomsMessageDetail(transaction: transaction, isResponse: true, vm: vm)
                }
            } else {
                ContentUnavailableView("选择一条请求", systemImage: "cursorarrow.click",
                                       description: Text("查看真实的请求头、响应头、正文与改写结果。"))
            }
        }
    }
}

private struct CustomsOverview: View {
    let transaction: CustomsTransaction

    var body: some View {
        if let finishedAt = transaction.finishedAt {
            content(at: finishedAt)
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                content(at: timeline.date)
            }
        }
    }

    private func content(at now: Date) -> some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                row("URL", transaction.url)
                row("域名", transaction.host)
                row("路径", transaction.path)
                row("Method", transaction.method)
                row("状态", CustomsDisplay.status(transaction))
                row("开始时间", transaction.startedAt.formatted(date: .numeric, time: .standard))
                row("结束时间", transaction.finishedAt?.formatted(date: .numeric, time: .standard) ?? "尚未结束")
                row("耗时", elapsed(from: transaction.startedAt, to: transaction.finishedAt, now: now))
                row("处理阶段", transaction.error == nil ? transaction.phase.title : "失败于：\(transaction.phase.title)")
                row("阶段说明", transaction.phase.detail)
                if let handling = transaction.httpsHandling { row("HTTPS 处理", handling.title) }
                ForEach(Array(transaction.phaseTimings.enumerated()), id: \.offset) { _, timing in
                    row(timing.phase.title, elapsed(from: timing.startedAt, to: timing.finishedAt, now: now))
                }
                row("响应来源", transaction.responseIsLocal ? "代理生成的诊断响应，不是源站响应" : (transaction.isTunnel ? "加密隧道；200 只表示隧道建立" : (transaction.statusCode == nil ? "尚未收到源站响应头" : "源站响应")))
                row("响应字节", transaction.isTunnel && !transaction.responseIsLocal ? "不统计加密隧道内的 HTTP 正文" : "\(transaction.responseByteCount) B（\(CustomsDisplay.size(transaction.responseByteCount))）")
                row("正文已捕获", "请求 \(transaction.requestBody.count) B / 响应 \(transaction.responseBody.count) B")
                row("改写字段", transaction.rewrittenHeaders.isEmpty ? "无" : transaction.rewrittenHeaders.joined(separator: ", "))
                if transaction.requestBodyTruncated || transaction.responseBodyTruncated {
                    row("截断", "\(transaction.requestBodyTruncated ? "请求正文已截断。" : "")\(transaction.responseBodyTruncated ? "响应正文已截断。" : "")每侧最多保留 512 KiB。")
                }
                if transaction.requestBodyIncomplete {
                    row("上传", "正文未完整上传（可能被源站提前拒绝），禁止生成不完整的重放 cURL。")
                }
                if transaction.isTunnel {
                    row(transaction.method == "CONNECT" ? "CONNECT" : "连接说明", transaction.connectNotice)
                }
                if let error = transaction.error { row("错误", error) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    private func elapsed(from start: Date, to end: Date?, now: Date) -> String {
        String(format: "%.0f ms%@", max(0, (end ?? now).timeIntervalSince(start)) * 1000,
               end == nil ? "（进行中）" : "")
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

private enum CustomsMessageTab: String, CaseIterable {
    case headers = "Headers", body = "Body"
}

private struct CustomsMessageDetail: View {
    let transaction: CustomsTransaction
    let isResponse: Bool
    @ObservedObject var vm: CustomsViewModel
    @State private var tab: CustomsMessageTab = .headers
    @State private var original = false
    @State private var prettyJSON = true

    private var headers: [CustomsHeader] {
        isResponse ? transaction.responseHeaders : (original ? transaction.originalRequestHeaders : transaction.requestHeaders)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("内容", selection: $tab) {
                    ForEach(CustomsMessageTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 170)
                if !isResponse {
                    Picker("请求版本", selection: $original) {
                        Text("原始").tag(true)
                        Text("改写后").tag(false)
                    }
                    .pickerStyle(.segmented).frame(width: 165)
                }
                Spacer()
                if tab == .body {
                    Picker("正文显示", selection: $prettyJSON) {
                        Text("Raw").tag(false)
                        Text("Pretty JSON").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 170)
                        .help("Raw 为展示解压后的未格式化文本；Pretty JSON 仅格式化展示，不修改 wire 或 Headers")
                }
            }
            .font(.caption).padding(10)
            if isResponse && transaction.responseIsLocal {
                CustomsInlineNotice(text: "这是海关返回给客户端的本地诊断响应，不是源站响应。具体原因见下方 Body 或概要中的错误。", warning: true)
            }
            if let error = transaction.error {
                CustomsInlineNotice(text: "请求错误：\(error)\(transaction.responseIsLocal ? "" : "。下方仅显示已捕获内容，不能视为完整响应。")", warning: true)
            } else if transaction.finishedAt == nil {
                CustomsInlineNotice(text: "\(transaction.phase.title)：\(transaction.phase.detail)", warning: false)
            }
            if !isResponse && transaction.requestBodyIncomplete {
                CustomsInlineNotice(text: "上传未完整结束，下方仅为已捕获的部分正文；此请求不可完整复制为 cURL。", warning: true)
            }
            if transaction.isTunnel {
                CustomsInlineNotice(text: transaction.connectNotice, warning: transaction.error != nil)
                if transaction.method == "CONNECT", let relatedID = transaction.relatedTransactionID {
                    Button("查看解密后的请求") { vm.selectTreeTransaction(id: relatedID) }
                        .disabled(!vm.treeFilteredTransactions.contains { $0.id == relatedID })
                        .help("跳转到此 CONNECT 关联的真实 HTTP 请求；若记录被清除或过滤，请先调整筛选。")
                        .padding(.vertical, 6)
                }
            }
            if tab == .headers {
                ResponseTextEditor(text: headerText)
            } else if transaction.isTunnel && !(isResponse && transaction.responseIsLocal) {
                ResponseTextEditor(text: transaction.connectNotice)
            } else {
                CustomsBodyPreview(
                    data: isResponse ? transaction.responseBody : transaction.requestBody,
                    headers: headers,
                    truncated: isResponse ? transaction.responseBodyTruncated : transaction.requestBodyTruncated,
                    totalBytes: isResponse ? transaction.responseByteCount : nil,
                    finished: isResponse ? transaction.finishedAt != nil : (transaction.requestBodyComplete || transaction.finishedAt != nil),
                    incomplete: !isResponse && transaction.requestBodyIncomplete,
                    error: transaction.error,
                    prettyJSON: prettyJSON
                )
            }
        }
    }

    private var headerText: String {
        if headers.isEmpty {
            if isResponse && transaction.isTunnel {
                return transaction.connectNotice
            }
            if isResponse && transaction.error != nil { return "请求失败，未捕获到响应 Headers。" }
            if isResponse && transaction.finishedAt == nil { return "等待响应 Headers…" }
            return "未捕获到 Headers。"
        }
        return headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }
}

private struct CustomsInlineNotice: View {
    let text: String
    var warning = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle")
            Text(text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(warning ? Color.orange : Color.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

@MainActor
private struct CustomsBodyPreview: View {
    let data: Data
    let headers: [CustomsHeader]
    let truncated: Bool
    let totalBytes: Int?
    let finished: Bool
    let incomplete: Bool
    let error: String?
    let prettyJSON: Bool
    @State private var preview: CustomsDisplay.Body?
    @State private var renderedSignature: Signature?

    private struct Signature: Hashable, Sendable {
        let data: Data
        let headerFields: [String]
        let truncated: Bool
        let totalBytes: Int?
        let finished: Bool
        let incomplete: Bool
        let error: String?
        let prettyJSON: Bool
    }

    private var signature: Signature {
        Signature(data: data, headerFields: headers.flatMap { [$0.name, $0.value] },
                  truncated: truncated, totalBytes: totalBytes, finished: finished, incomplete: incomplete,
                  error: error, prettyJSON: prettyJSON)
    }

    var body: some View {
        let input = signature
        VStack(spacing: 0) {
            if renderedSignature == input, let preview {
                CustomsInlineNotice(text: preview.notice, warning: preview.warning)
                ResponseTextEditor(text: preview.text)
            } else {
                ProgressView("准备正文展示…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: input) { @MainActor in
            let capturedHeaders = headers
            let work = Task.detached(priority: .userInitiated) {
                CustomsDisplay.body(data: input.data, headers: capturedHeaders, truncated: input.truncated,
                                    totalBytes: input.totalBytes, finished: input.finished,
                                    error: input.error, prettyJSON: input.prettyJSON, incomplete: input.incomplete)
            }
            let result = await withTaskCancellationHandler(operation: {
                await work.value
            }, onCancel: {
                work.cancel()
            })
            // This task inherits MainActor. Cancelled / superseded work must not publish.
            guard !Task.isCancelled else { return }
            preview = result
            renderedSignature = input
        }
    }
}

nonisolated private enum CustomsDisplay {
    static let previewLimit = 512 * 1024

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func duration(_ transaction: CustomsTransaction) -> String {
        let value = String(format: "%.0f ms", transaction.duration * 1000)
        return transaction.finishedAt == nil ? "进行中" : value
    }

    static func status(_ transaction: CustomsTransaction) -> String {
        if transaction.responseIsLocal { return transaction.statusCode.map { "\($0) · 代理" } ?? "代理错误" }
        if transaction.error != nil { return transaction.statusCode.map { "\($0) · 错误" } ?? "错误" }
        if transaction.isTunnel && transaction.statusCode == 200 {
            return transaction.finishedAt == nil ? "隧道已建" : "隧道结束"
        }
        if let code = transaction.statusCode { return String(code) }
        return transaction.finishedAt == nil ? transaction.phase.title : "—"
    }

    static func statusColor(_ transaction: CustomsTransaction) -> Color {
        if transaction.error != nil { return .red }
        guard let code = transaction.statusCode else { return .secondary }
        if code >= 400 { return .orange }
        if code >= 200 && code < 300 { return .green }
        return .primary
    }

    struct Body: Sendable {
        let text: String
        let notice: String
        var warning = false
    }

    static func body(data: Data, headers: [CustomsHeader], truncated: Bool, totalBytes: Int?,
                     finished: Bool, error: String?, prettyJSON: Bool, incomplete: Bool = false) -> Body {
        let clipped = truncated || data.count > previewLimit
        let wire = Data(data.prefix(previewLimit))
        var notice = "已捕获 wire 正文 \(data.count) B"
        if let totalBytes { notice += " · wire 正文总计 \(totalBytes) B" }
        if clipped { notice += " · 捕获正文已截断" }
        if incomplete { notice += " · 上传已终止，仅展示已捕获部分" }
        notice += " · 只读，可用 ⌘A / ⌘C"
        if wire.isEmpty {
            let text: String
            if error != nil { text = "请求失败；没有捕获到正文，不能据此判断原响应为空。" }
            else if incomplete { text = "上传已终止，尚未捕获正文；不能据此判断原请求正文为空。" }
            else if !finished { text = "尚未捕获正文，等待数据到达；不是正在解析已有正文。" }
            else { text = "没有捕获到正文（例如 HEAD / 204 / 空正文）。" }
            return Body(text: text, notice: notice, warning: clipped || incomplete)
        }
        let encoding = headers.filter { $0.name.caseInsensitiveCompare("content-encoding") == .orderedSame }
            .map(\.value).joined(separator: ", ")
        let output: CustomsBodyDecoder.Output
        do {
            output = try CustomsBodyDecoder.decode(data: wire, contentEncoding: encoding, truncated: clipped)
        } catch {
            return Body(text: "\(error.localizedDescription)\n\n原始 wire 正文未改变。\n\(hex(wire))",
                        notice: notice + " · 无法解压，回退原始 wire Hex", warning: true)
        }
        if !output.decodedEncodings.isEmpty {
            notice += " · \(output.decodedEncodings.joined(separator: ", ")) 展示解压后 \(output.data.count) B（上限 512 KiB）"
        }
        let bytes = output.data
        guard !Task.isCancelled else { return Body(text: "", notice: "展示任务已取消") }
        let decoded = String(data: bytes, encoding: .utf8)
        let isText = decoded?.unicodeScalars.allSatisfy { $0.value >= 32 || $0 == "\n" || $0 == "\r" || $0 == "\t" } ?? false
        guard isText else {
            return Body(text: "二进制或非 UTF-8 正文，不猜测文本编码。\n\(hex(bytes))",
                        notice: notice + (output.decodedEncodings.isEmpty ? " · wire Hex" : " · 解压后的 Hex"), warning: clipped)
        }
        if prettyJSON && !clipped {
            if let object = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
               !Task.isCancelled,
               let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
                if formatted.count <= previewLimit, let text = String(data: formatted, encoding: .utf8) {
                    return Body(text: text, notice: notice + " · Pretty JSON（仅展示，wire / Headers 未改动）")
                }
                notice += " · 格式化结果超过 512 KiB，显示 Raw"
            } else { notice += " · 非完整有效 JSON，显示 Raw" }
        }
        return Body(text: decoded ?? "", notice: notice + (clipped ? " · 截断 Raw，不进行 JSON 格式化" : " · Raw UTF-8（未格式化文本）"), warning: clipped)
    }

    private static func hex(_ bytes: Data) -> String {
        let prefix = bytes.prefix(512)
        let rows = stride(from: 0, to: prefix.count, by: 16).map { offset in
            String(format: "%08X  ", offset) + prefix.dropFirst(offset).prefix(16)
                .map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        return "Hex 前 \(prefix.count) B / 当前展示数据 \(bytes.count) B：\n" + rows.joined(separator: "\n")
    }
}

@MainActor
private struct CustomsRulesSheet: View {
    @ObservedObject var vm: CustomsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [CustomsHeaderRule] = []
    @State private var presetID: UUID?
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Header 改写规则").font(.title2.weight(.semibold))
            Text("保存后对后续请求实时生效，无需重启代理；关闭或取消不会应用本次修改。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("启用").frame(width: 38)
                Text("Header 名称").frame(width: 170, alignment: .leading)
                Text("值（空值不注入）")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($draft) { $rule in
                        HStack(spacing: 10) {
                            Toggle("启用字段", isOn: $rule.isEnabled).labelsHidden().frame(width: 38)
                            TextField("例如 X-Debug", text: $rule.name)
                                .frame(width: 170).disabled(rule.id == presetID)
                            TextField("空值不注入", text: $rule.value)
                            Button(role: .destructive) { draft.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .disabled(rule.id == presetID)
                            .help(rule.id == presetID ? "swimlane 预设不可删除，可禁用或清空值" : "删除字段")
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 140, maxHeight: 280)
            Button { draft.append(CustomsHeaderRule()) } label: {
                Label("新增字段", systemImage: "plus")
            }
            CustomsInlineNotice(text: "swimlane 预设不可删除，可禁用或清空。仅启用且有值的规则注入请求；启用规则的 Header 名称必须唯一（大小写不敏感）；与原请求同名的 Header 将被覆盖。代理、连接及报文边界字段不可改写。")
            Text("仅规则和配置持久化。规则值可能包含敏感信息，请勿保存 Cookie、令牌或密码。")
                .font(.caption).foregroundStyle(.orange)
            if let validationError { Text(validationError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                Text(vm.rewriteEnabled ? "全局改写已启用" : "全局改写已关闭；保存不会自动打开")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并应用", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 720)
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        draft = vm.headerRules
        if let rule = draft.first(where: { $0.name.caseInsensitiveCompare("swimlane") == .orderedSame }) {
            presetID = rule.id
        } else {
            let preset = CustomsHeaderRule(name: "swimlane")
            draft.insert(preset, at: 0)
            presetID = preset.id
        }
    }

    private func save() {
        // Validate using the same policy as the view model, restoring it on failure.
        let previous = vm.headerRules
        vm.headerRules = draft
        if let error = vm.validateRules() {
            vm.headerRules = previous
            validationError = error
            return
        }
        vm.saveRules()
        dismiss()
    }
}

@MainActor
private struct CustomsConfigurationSheet: View {
    @ObservedObject var vm: CustomsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLAN = false
    @State private var validationError: String?
    @State private var certificateSheet: CertificateSheet?

    private enum CertificateSheet: String, Identifiable {
        case management, help
        var id: String { rawValue }
    }

    private var locked: Bool { vm.isRunning || vm.isStarting }
    private var lanBinding: Binding<Bool> {
        Binding(get: { vm.listenOnLAN }, set: { enabled in
            if enabled { confirmingLAN = true } else { vm.listenOnLAN = false }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("代理设置").font(.title2.weight(.semibold))
            if locked {
                CustomsInlineNotice(text: "代理运行中。请先停止代理再修改端口、监听范围或 HTTPS 配置。")
            }
            Form {
                TextField("监听端口", text: $vm.portText).frame(maxWidth: 300)
                Toggle("允许局域网设备连接", isOn: lanBinding)
                Text("默认允许局域网设备连接，可手动关闭。启用 LAN 会暴露调试代理，请仅在受信任网络使用。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("解密 HTTPS", isOn: $vm.decryptHTTPS)
                Text("默认开启；仅对指定域名进行解密，可手动关闭。客户端必须安装并信任当前 CA，且使用此代理。")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSL 解密域名（逗号或换行分隔）")
                    TextEditor(text: $vm.sslHostsText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 78)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                    Text("* 匹配所有域名；可使用 api.example.com 或 *.example.com。建议缩小解密范围。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!vm.decryptHTTPS)
            }
            .formStyle(.grouped).disabled(locked)
            CustomsInlineNotice(text: "仅支持 HTTP/1.1（兼容 HTTP/1.0），目前不支持 WebSocket 抓包。使用 SSL pinning 的 App 可能拒绝代理证书；安装 CA 不会绕过证书固定。不会自动修改系统代理。仅在你主动确认安装后，设置当前用户的 SSL 根证书信任；无默认自动信任。")
            certificateButtons
            if let validationError { Text(validationError).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                Text("配置与规则持久化，抓包正文不保存。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成", action: finish).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 640)
        .interactiveDismissDisabled()
        .sheet(item: $certificateSheet) { destination in
            switch destination {
            case .management: CustomsCertificateView(vm: vm)
            case .help: CustomsCertificateHelpView(vm: vm)
            }
        }
        .alert("允许局域网访问调试代理？", isPresented: $confirmingLAN) {
            Button("取消", role: .cancel) { }
            Button("确认启用 LAN", role: .destructive) {
                if !locked { vm.listenOnLAN = true }
            }
        } message: {
            Text("同一网络的设备可能通过此代理访问网络；代理可能接触请求中的 Cookie、令牌和敏感正文。请只在受信任网络启用，避免公网暴露，并在调试结束后停止代理。")
        }
    }

    private var certificateButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("证书与信任").font(.headline)
                Button { certificateSheet = .help } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .help("证书助手：原理、安装、手机配置与排障")
                .accessibilityLabel("打开证书助手")
                Spacer()
                Button("打开证书管理…") { certificateSheet = .management }
            }
            Text("查看 CA 指纹与本机信任、确认安装或撤销、临时向手机分享公钥。安装本机 CA 不代表手机已信任。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func finish() {
        if !locked {
            let text = vm.portText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = UInt16(text), port >= 1024 else {
                validationError = "端口必须为 1024–65535 的整数。"
                return
            }
            if vm.decryptHTTPS && vm.sslHostsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationError = "启用 HTTPS 解密时，请填写至少一个 SSL 域名。"
                return
            }
            vm.portText = text
            vm.saveRules()
        }
        dismiss()
    }
}
