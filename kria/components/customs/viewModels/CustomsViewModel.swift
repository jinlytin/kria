import AppKit
import Combine
import Foundation

@MainActor
final class CustomsViewModel: ObservableObject {
    @Published var transactions: [CustomsTransaction] = [] {
        didSet { reconcileTreeSelection() }
    }
    @Published var selectedID: UUID?
    @Published var selectedHost: String? {
        didSet {
            if selectedHost != oldValue { selectedPath = nil }
            reconcileTreeSelection()
        }
    }
    @Published private(set) var selectedPath: String?
    @Published var searchText = "" {
        didSet { reconcileTreeSelection() }
    }
    @Published var treeSearchText = "" {
        didSet { reconcileTreeSelection() }
    }
    private var reconcilingSelection = false
    @Published var portText = "8888"
    @Published var listenOnLAN = true
    @Published var decryptHTTPS = true
    @Published var sslHostsText = "*"
    @Published var rewriteEnabled = true
    @Published var headerRules = [CustomsHeaderRule(name: "swimlane")]
    @Published var isRecording = true
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published var message: String?
    @Published private(set) var certificateBusy = false
    @Published private(set) var certificateInfo: CustomsCertificateInfo?
    @Published private(set) var certificateError: String?
    @Published private(set) var downloadSession: CustomsCertificateDownloadSession?
    @Published private var localIPv4Addresses: [String] = []

    private let certificateManager: CustomsCertificateManager
    private let certificateDownloadServer: CustomsCertificateDownloadServer
    private var downloadGeneration = UUID()
    private var downloadExpiryTask: Task<Void, Never>?
    private(set) var certificateTask: Task<Void, Never>?

    private var server: CustomsProxyServer?
    private var epoch = UUID()
    private var ignoredIDs: Set<UUID> = []
    private var clearedAt = Date.distantPast
    private let storageURL: URL
    private var capturedBytes = 0
    private let memoryLimit = 64 * 1024 * 1024

    init(storageURL: URL? = nil,
         certificateManager: CustomsCertificateManager = CustomsCertificateManager(),
         certificateDownloadServer: CustomsCertificateDownloadServer = CustomsCertificateDownloadServer()) {
        self.certificateManager = certificateManager
        self.certificateDownloadServer = certificateDownloadServer
        localIPv4Addresses = CustomsCertificateDownloadServer.localIPv4Addresses()
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kria/Customs/settings.json")
        loadSettings()
    }

    var endpoint: String { "127.0.0.1:\(portText)" }
    var localProxyAddresses: [String] { localIPv4Addresses.map { "\($0):\(portText)" } }
    var hosts: [String] { Array(Set(transactions.map(\.host))).sorted() }
    var selectedTransaction: CustomsTransaction? { filteredTransactions.first { $0.id == selectedID } }
    var isTreeSearching: Bool { !treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Tree and sequence share the same search result pool. Tree selection narrows only the sequence,
    /// so selecting one branch does not hide its sibling domains or change the search query.
    var treeFilteredTransactions: [CustomsTransaction] {
        let treeSearch = treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return transactions.filter { transaction in
            let treeMatches = treeSearch.isEmpty || transaction.host.localizedCaseInsensitiveContains(treeSearch) ||
                transaction.path.localizedCaseInsensitiveContains(treeSearch) ||
                transaction.url.localizedCaseInsensitiveContains(treeSearch) ||
                transaction.url.removingPercentEncoding?.localizedCaseInsensitiveContains(treeSearch) == true
            let sequenceMatches = search.isEmpty || transaction.url.localizedCaseInsensitiveContains(search) ||
                transaction.method.localizedCaseInsensitiveContains(search) ||
                String(transaction.statusCode ?? 0).contains(search) ||
                transaction.error?.localizedCaseInsensitiveContains(search) == true
            return treeMatches && sequenceMatches
        }
    }
    var filteredTransactions: [CustomsTransaction] {
        treeFilteredTransactions.filter {
            (selectedHost == nil || $0.host == selectedHost) &&
            (selectedPath == nil || $0.groupingPath == selectedPath)
        }
    }
    var requestTreeNodes: [CustomsRequestTreeNode] {
        let grouped = Dictionary(grouping: treeFilteredTransactions, by: \.host)
        return grouped.keys.sorted().map { host in
            let requests = grouped[host] ?? []
            let paths = Dictionary(grouping: requests, by: \.groupingPath)
            let children = paths.keys.sorted().map { path in
                let records = paths[path] ?? []
                let leaves = records.map { transaction in
                    CustomsRequestTreeNode(host: host, path: path, count: 1, transaction: transaction)
                }
                return CustomsRequestTreeNode(host: host, path: path, count: records.count, children: leaves)
            }
            return CustomsRequestTreeNode(host: host, path: nil, count: requests.count, children: children)
        }
    }
    func selectTreeNode(host: String?, path: String? = nil) {
        guard host == nil || treeFilteredTransactions.contains(where: { $0.host == host && (path == nil || $0.groupingPath == path) }) else { return }
        reconcilingSelection = true
        selectedHost = host; selectedPath = host == nil ? nil : path
        reconcilingSelection = false
        reconcileTreeSelection()
    }
    func selectTreeTransaction(id: UUID) {
        guard let transaction = treeFilteredTransactions.first(where: { $0.id == id }) else { return }
        reconcilingSelection = true
        selectedHost = transaction.host; selectedPath = transaction.groupingPath; selectedID = id
        reconcilingSelection = false
        reconcileTreeSelection()
    }
    func resetRequestFilters() {
        reconcilingSelection = true
        selectedHost = nil; selectedPath = nil; searchText = ""; treeSearchText = ""
        reconcilingSelection = false
        reconcileTreeSelection()
    }
    private func reconcileTreeSelection() {
        guard !reconcilingSelection else { return }
        reconcilingSelection = true
        defer { reconcilingSelection = false }
        let matches = treeFilteredTransactions
        if let host = selectedHost {
            if !matches.contains(where: { $0.host == host }) {
                selectedHost = nil; selectedPath = nil
            } else if let path = selectedPath, !matches.contains(where: { $0.host == host && $0.groupingPath == path }) {
                selectedPath = nil
            }
        }
        let visible = matches.filter {
            (selectedHost == nil || $0.host == selectedHost) && (selectedPath == nil || $0.groupingPath == selectedPath)
        }
        if selectedID == nil || !visible.contains(where: { $0.id == selectedID }) {
            selectedID = visible.first?.id
        }
    }

    func validateRules() -> String? {
        var seen: Set<String> = []
        for rule in headerRules where rule.isEnabled {
            if rule.name.isEmpty && rule.value.isEmpty { continue }
            if let error = CustomsHTTP.validateRule(rule) { return "\(rule.name): \(error)" }
            guard seen.insert(rule.name.lowercased()).inserted else { return "Header 名称重复：\(rule.name)（大小写不敏感）" }
        }
        return nil
    }

    func toggleProxy() {
        if isRunning || isStarting { shutdown(); return }
        guard !certificateBusy else { message = "证书操作进行中，请完成后再启动代理"; return }
        guard let port = UInt16(portText), port >= 1024 else { message = "端口应为 1024–65535 的整数"; return }
        guard let error = validateRules() else {
            let patterns = sslHostsText.components(separatedBy: CharacterSet(charactersIn: ",\n "))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
            for pattern in patterns where pattern != "*" {
                let host = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
                guard (try? CustomsCertificateAuthority.validatedHost(host)) != nil else { message = "SSL 域名无效：\(pattern)"; return }
            }
            if decryptHTTPS && patterns.isEmpty { message = "开启 HTTPS 解密时请至少填写一个 SSL 域名范围"; return }
            saveRules()
            refreshProxyAddresses()
            isStarting = true; message = nil
            epoch = UUID()
            let currentEpoch = epoch
            let server = CustomsProxyServer { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == currentEpoch else { return }
                    self.receive(event)
                }
            }
            self.server = server
            server.setRecording(isRecording)
            do {
                try server.start(configuration: .init(port: port, listenOnLAN: listenOnLAN, decryptHTTPS: decryptHTTPS,
                    sslHosts: patterns, rewriteEnabled: rewriteEnabled, headerRules: headerRules))
            } catch {
                self.server = nil; isStarting = false; message = error.localizedDescription
            }
            return
        }
        message = error
    }

    private func receive(_ event: CustomsProxyEvent) {
        switch event {
        case .started: isStarting = false; isRunning = true
        case .stopped: isStarting = false; isRunning = false
        case .failed(let error): message = error
        case .transaction(let value):
            guard value.startedAt > clearedAt, !ignoredIDs.contains(value.id) else { return }
            if let index = transactions.firstIndex(where: { $0.id == value.id }) {
                capturedBytes -= transactions[index].requestBody.count + transactions[index].responseBody.count
                transactions[index] = value
            } else {
                transactions.append(value)
            }
            capturedBytes += value.requestBody.count + value.responseBody.count
            // Count and body-byte budgets are independent; large responses must not consume a gigabyte.
            while transactions.count > 1000 || capturedBytes > memoryLimit {
                let removed = transactions.removeFirst()
                capturedBytes -= removed.requestBody.count + removed.responseBody.count
                if removed.finishedAt == nil { ignoredIDs.insert(removed.id) }
            }
        }
    }

    func toggleRecording() { isRecording.toggle(); server?.setRecording(isRecording) }
    func clear() {
        clearedAt = Date(); transactions.removeAll(); ignoredIDs.removeAll()
        selectedID = nil; selectedHost = nil; selectedPath = nil; capturedBytes = 0
    }
    func saveRules() {
        if let error = validateRules() { message = error; return }
        if !headerRules.contains(where: { $0.name.caseInsensitiveCompare("swimlane") == .orderedSame }) {
            headerRules.insert(CustomsHeaderRule(name: "swimlane"), at: 0)
        }
        server?.updateRules(headerRules, enabled: rewriteEnabled)
        do {
            let settings = Settings(port: portText, listenOnLAN: listenOnLAN, decryptHTTPS: decryptHTTPS,
                                    sslHosts: sslHostsText, rewriteEnabled: rewriteEnabled, headerRules: headerRules)
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(settings).write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            message = nil
        } catch { message = "配置保存失败：\(error.localizedDescription)" }
    }
    private struct Settings: Codable {
        var port: String
        var listenOnLAN: Bool
        var decryptHTTPS: Bool
        var sslHosts: String
        var rewriteEnabled: Bool
        var headerRules: [CustomsHeaderRule]
    }
    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: storageURL))
            portText = settings.port; decryptHTTPS = settings.decryptHTTPS; sslHostsText = settings.sslHosts
            listenOnLAN = settings.listenOnLAN
            rewriteEnabled = settings.rewriteEnabled; headerRules = settings.headerRules
            if !headerRules.contains(where: { $0.name.caseInsensitiveCompare("swimlane") == .orderedSame }) {
                headerRules.insert(CustomsHeaderRule(name: "swimlane"), at: 0)
            }
        } catch { message = "配置读取失败：\(error.localizedDescription)" }
    }

    /// All certificate work is serialized off the UI thread. Reading never generates or changes trust.
    private func certificateOperation(success: String? = nil,
                                      _ operation: @escaping @Sendable (CustomsCertificateManager) throws -> CustomsCertificateInfo?) {
        guard !certificateBusy else { return }
        certificateBusy = true
        let manager = certificateManager
        certificateTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try operation(manager) }
            }.value
            guard let self else { return }
            self.certificateBusy = false
            self.localIPv4Addresses = CustomsCertificateDownloadServer.localIPv4Addresses()
            switch result {
            case .success(let info):
                self.certificateInfo = info; self.certificateError = nil
                if let success { self.message = success }
            case .failure(let error):
                self.certificateError = error.localizedDescription
                self.message = error.localizedDescription
            }
        }
    }

    func refreshCertificateStatus() {
        certificateOperation { try $0.inspect() }
    }
    func prepareCertificate() {
        guard !isRunning, !isStarting else { message = "请先停止代理再生成 CA"; return }
        certificateOperation(success: "CA 已生成，尚未自动信任。请核对指纹后主动安装；不要分享私钥。") { try $0.prepare() }
    }
    func installCertificate() {
        guard let fingerprint = certificateInfo?.sha256Fingerprint else {
            certificateError = "请先读取当前 CA 并核对指纹再安装"; return
        }
        certificateOperation(success: "安装命令已完成，请核对下方实际 SSL 信任结果；本机信任不代表手机已信任。") { try $0.installAndTrust(expectedFingerprint: fingerprint) }
    }
    func removeCertificateTrust() {
        guard !certificateBusy else { return }
        stopCertificateDownload()
        let fingerprint = certificateInfo?.sha256Fingerprint
        certificateOperation(success: "已清理当前 CA 的用户信任与登录钥匙串公钥。管理员域和手机信任未修改。") { try $0.removeUserTrust(expectedFingerprint: fingerprint) }
    }
    func resetCertificate() {
        guard !certificateBusy, !isRunning, !isStarting, downloadSession == nil else {
            message = "重置前请先停止代理与临时下载，并等待当前证书操作结束"; return
        }
        stopCertificateDownload()
        let fingerprint = certificateInfo?.sha256Fingerprint
        certificateOperation(success: "CA 已更换，未自动信任。所有调试设备需移除旧 CA，并重新核对和安装新证书；无法识别的旧信任需手动清理。") { manager in
            try manager.authority.coordinated {
                // A previously displayed fingerprint cannot block recovery of an unreadable CA.
                // If the public certificate is readable, still bind reset to the confirmed identity.
                let readableDER = try? manager.authority.existingCertificateDER()
                return try manager.reset(expectedFingerprint: readableDER == nil ? nil : fingerprint)
            }
        }
    }
    func revealCertificate() {
        guard !certificateBusy else { return }
        certificateBusy = true
        let authority = certificateManager.authority
        certificateTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try authority.publicDER() }
            }.value
            guard let self else { return }
            self.certificateBusy = false
            switch result {
            case .failure(let error): self.certificateError = error.localizedDescription
            case .success(let data):
                let panel = NSSavePanel()
                panel.title = "导出海关 CA 公钥证书（不含私钥）"
                panel.nameFieldStringValue = "KriaCustomsCA.cer"
                panel.begin { [weak self] result in
                    guard result == .OK, let destination = panel.url else { return }
                    do {
                        try data.write(to: destination, options: .atomic)
                        self?.message = "已导出 CA 公钥证书，不含私钥。"
                    } catch { self?.certificateError = "导出失败：\(error.localizedDescription)" }
                }
            }
        }
    }
    func openCertificateInKeychain() {
        // Open the app only; opening the .crt itself would launch an import flow.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") else {
            certificateError = "找不到钥匙串访问，请使用 Spotlight 手动打开"; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error {
                Task { @MainActor [weak self] in self?.certificateError = error.localizedDescription }
            }
        }
    }
    func copyCertificateFingerprint() {
        guard let fingerprint = certificateInfo?.sha256Fingerprint else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fingerprint, forType: .string)
    }
    func startCertificateDownload(listenOnLAN: Bool = true, duration: TimeInterval = 600) {
        guard !certificateBusy, downloadSession == nil else { return }
        certificateBusy = true
        downloadGeneration = UUID()
        let generation = downloadGeneration
        let manager = certificateManager
        certificateTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try manager.authority.coordinated {
                        guard let info = try manager.inspect() else { throw CustomsBackendError.message("请先生成 CA 再开启公钥分享") }
                        return (info, try manager.authority.publicDER())
                    }
                }
            }.value
            guard let self else { return }
            self.certificateBusy = false
            // A stop/shutdown during preparation must not resurrect a LAN listener.
            guard self.downloadGeneration == generation else { return }
            do {
                let (info, data) = try result.get()
                self.certificateInfo = info; self.certificateError = nil
                let session = try self.certificateDownloadServer.start(certificateDER: data, fingerprint: info.sha256Fingerprint, listenOnLAN: listenOnLAN, duration: duration)
                self.downloadSession = session
                self.downloadExpiryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, session.expiresAt.timeIntervalSinceNow)))
                    guard !Task.isCancelled, let self, self.downloadGeneration == generation else { return }
                    self.stopCertificateDownload()
                    self.message = "临时公钥分享已到期并停止。已安装证书仍需在设备上自行移除。"
                }
                self.message = "已开启 10 分钟临时公钥下载。分享端口不是代理端口；手机安装前请核对 Mac 指纹。"
            } catch { self.certificateError = error.localizedDescription }
        }
    }
    func stopCertificateDownload() {
        downloadGeneration = UUID()
        downloadExpiryTask?.cancel(); downloadExpiryTask = nil
        certificateDownloadServer.stop(); downloadSession = nil
    }
    func copyCertificateDownloadURL(_ url: String) {
        guard let session = downloadSession, session.expiresAt > Date(), session.urls.contains(url) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
    }
    func copyCurl(original: Bool = false) {
        guard let curl = selectedTransaction?.curl(original: original) else { message = "仅完整且成功结束的 HTTP 请求支持复制；隧道/截断/失败请求不可完整重放"; return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(curl, forType: .string)
        message = "已复制 cURL，含真实请求参数，请注意脱敏。复制不会发送请求。"
    }
    func refreshProxyAddresses() {
        CustomsSocket.refreshDNSCache()
        localIPv4Addresses = CustomsCertificateDownloadServer.localIPv4Addresses()
    }
    func copyProxyAddress(_ address: String) {
        guard address == endpoint || localProxyAddresses.contains(address) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
    }
    func copyEndpoint() { copyProxyAddress(endpoint) }
    func shutdown() {
        stopCertificateDownload()
        epoch = UUID(); server?.stop(); server = nil; isRunning = false; isStarting = false
        for index in transactions.indices where transactions[index].finishedAt == nil {
            transactions[index].error = "代理已停止，连接已取消"
            transactions[index].finishTiming()
        }
        ignoredIDs.removeAll()
    }
}
