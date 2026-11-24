import Foundation

struct CustomsHeaderRule: Identifiable, Codable, Sendable {
    var id = UUID()
    var isEnabled = true
    var name = ""
    var value = ""
}

struct CustomsProxyConfiguration: Sendable {
    var port: UInt16
    var listenOnLAN: Bool
    var decryptHTTPS: Bool
    var sslHosts: [String]
    var rewriteEnabled: Bool
    var headerRules: [CustomsHeaderRule]
}

struct CustomsHeader: Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

enum CustomsRequestPhase: String, Sendable {
    case captured, dns, connecting, certificate, upstreamTLS, clientTLS, clientRequest
    case sendingRequest, waitingResponse, receivingResponse, tunnel, completed

    var title: String {
        switch self {
        case .captured: return "请求头已解析"
        case .dns: return "DNS 解析/排队"
        case .connecting: return "连接上游"
        case .certificate: return "准备域名证书"
        case .upstreamTLS: return "上游 TLS 握手"
        case .clientTLS: return "客户端 TLS 握手"
        case .clientRequest: return "等待客户端请求"
        case .sendingRequest: return "转发请求/上传正文"
        case .waitingResponse: return "等待源站响应"
        case .receivingResponse: return "接收响应正文"
        case .tunnel: return "转发加密隧道"
        case .completed: return "已完成"
        }
    }

    var detail: String {
        switch self {
        case .captured: return "请求头和 URL 已解析；正文随上传捕获，不需要等待响应才能查看。"
        case .dns: return "请求头已解析，正在等待系统 DNS 返回或等待解析名额，不是在解析 HTTP 正文。"
        case .connecting: return "正在与上游建立 TCP 连接；多个地址会交错尝试，不等待首个地址超时才回退。"
        case .certificate: return "首次访问域名需要签发调试证书；已有有效证书会从缓存复用。"
        case .upstreamTLS: return "正在与源站进行 TLS 握手并验证源站证书；尚未开始发送解密后的 HTTP 请求。"
        case .clientTLS: return "正在与客户端进行 TLS 握手；客户端需信任当前 CA。"
        case .clientRequest: return "TLS 已建立，正在等待客户端发送解密后的 HTTP 请求头。"
        case .sendingRequest: return "请求头已解析，正在转发请求或等待客户端继续上传正文。"
        case .waitingResponse: return "请求已转发，正在等待源站响应头；等待的是网络/源站，不是本地解析。"
        case .receivingResponse: return "源站响应头已解析，正在接收并转发正文；已捕获部分可预览。"
        case .tunnel: return "仅转发加密数据；此 CONNECT 记录不含内部 HTTP 明文。"
        case .completed: return "网络转发已完成；正文解压和 JSON 格式化只用于后台展示。"
        }
    }
}

struct CustomsPhaseTiming: Sendable {
    var phase: CustomsRequestPhase
    var startedAt: Date
    var finishedAt: Date?
    var duration: TimeInterval { max(0, (finishedAt ?? Date()).timeIntervalSince(startedAt)) }
}

enum CustomsHTTPSHandling: Sendable {
    case disabled, hostExcluded, decrypting

    var title: String {
        switch self {
        case .disabled: return "未解密：启动代理时关闭了 HTTPS 解密"
        case .hostExcluded: return "未解密：目标域名不在 SSL 解密范围"
        case .decrypting: return "已启用 HTTPS 解密（MITM）"
        }
    }
}

struct CustomsTransaction: Identifiable, Sendable {
    var id = UUID()
    var startedAt = Date()
    var finishedAt: Date?
    var method: String
    var url: String
    var requestTarget: String?
    var requestHeaders: [CustomsHeader] = []
    var originalRequestHeaders: [CustomsHeader] = []
    var requestBody = Data()
    var requestBodyTruncated = false
    var requestBodyIncomplete = false
    var requestBodyComplete = false
    var phase: CustomsRequestPhase = .captured
    var phaseTimings: [CustomsPhaseTiming] = []
    var responseHeaders: [CustomsHeader] = []
    var responseBody = Data()
    var responseBodyTruncated = false
    var statusCode: Int?
    var error: String?
    var isTunnel = false
    /// The policy in effect for this CONNECT, not the current settings in the UI.
    var httpsHandling: CustomsHTTPSHandling?
    /// CONNECT points to its decrypted HTTP record; that HTTP record points back.
    var relatedTransactionID: UUID?
    var rewrittenHeaders: [String] = []
    var responseByteCount = 0
    /// A synthetic proxy error, not a response received from the origin.
    var responseIsLocal = false

    var host: String { URLComponents(string: url)?.host ?? url }
    /// Tree branches group by the encoded URL path only; query remains on each request.
    var groupingPath: String {
        if requestTarget == "*" { return "*" }
        guard let components = URLComponents(string: url) else { return url }
        return components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }
    var path: String {
        guard requestTarget != "*", let components = URLComponents(string: url) else { return groupingPath }
        return groupingPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
    mutating func advance(to next: CustomsRequestPhase, at time: Date = Date()) {
        guard finishedAt == nil, phaseTimings.isEmpty || phase != next else { return }
        if !phaseTimings.isEmpty { phaseTimings[phaseTimings.count - 1].finishedAt = time }
        phase = next
        if next != .completed { phaseTimings.append(.init(phase: next, startedAt: time)) }
    }
    mutating func finishTiming(at time: Date = Date()) {
        if !phaseTimings.isEmpty { phaseTimings[phaseTimings.count - 1].finishedAt = time }
        if error == nil { phase = .completed }
        finishedAt = time
    }
    var connectNotice: String {
        guard method == "CONNECT" else {
            return "此连接不是普通 HTTP 正文记录；不支持的 Upgrade 连接不会被当作 CONNECT 解密成功。"
        }
        let policy = httpsHandling?.title ?? "这条旧记录没有保存解密配置，不能判断当时是否启用了解密。"
        if let error {
            let stage = phaseTimings.isEmpty ? "未记录阶段" : phase.title
            let guidance: String
            switch phase {
            case .clientTLS:
                guidance = "客户端 TLS 握手未完成；可能是客户端中止、CA 信任问题或 App 证书绑定。不能仅凭连接重置认定 CA 未信任。"
            case .upstreamTLS:
                guidance = "源站 TLS 握手未完成；检查源站连通性、TLS 兼容性和源站证书。此阶段与 iPhone 是否信任代理 CA 无关。"
            case .clientRequest:
                guidance = "两端 TLS 握手已完成，但未拿到可解析的客户端 HTTP 请求；客户端可能中止或发送了不支持的协议。"
            case .tunnel:
                guidance = "未解密的加密流量转发已中断；查看错误中的读取/写入端点。这不是正文解析失败。"
            case .certificate:
                guidance = "代理准备域名证书时失败，尚未完成解密握手。"
            default:
                guidance = "连接在拿到可解析的 HTTP 请求前失败；先处理此错误，不要把空白正文当成源站空响应。"
            }
            return "\(policy)\n失败阶段：\(stage)\n错误：\(error)\n\(guidance)\nCONNECT 的 200（如果已发送）只代表接受隧道，不代表 HTTPS 请求成功。"
        }
        if httpsHandling == .decrypting {
            if relatedTransactionID != nil {
                return "\(policy)\n此 CONNECT 是握手记录，真实 HTTP 请求已生成关联记录，响应将在该记录中展示。请点击「查看解密后的请求」；不需要重复开启解密或安装证书。"
            }
            if finishedAt != nil {
                return "\(policy)\n两端 TLS 握手已完成，但关联 HTTP 请求未录制（收到请求时录制已暂停）。恢复录制后重新发起请求；此 CONNECT 本身没有 HTTP 正文。"
            }
            return "\(policy)\n当前阶段：\(phase.title)。真实 HTTP 请求尚未生成独立记录；此 CONNECT 本身没有 HTTP 正文。200 只表示接受隧道。"
        }
        if httpsHandling != nil {
            return "\(policy)\n本次仅转发加密字节，CONNECT 本身没有内部 HTTP 正文。若需抓取明文，请停止代理，开启 HTTPS 解密并确保 SSL 域名范围匹配；客户端信任当前 CA 后重新启动并发起请求。修改设置不会补解密这条已有记录。"
        }
        return "\(policy)\nCONNECT 本身不包含内部 HTTP 正文，200 只表示接受隧道。请使用当前版本重新抓取，查看处理阶段和解密配置。"
    }

    var canCopyCurl: Bool {
        let encodings = requestHeaders.filter { $0.name.caseInsensitiveCompare("transfer-encoding") == .orderedSame }
            .flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return finishedAt != nil && error == nil && !isTunnel && !requestBodyTruncated && !requestBodyIncomplete &&
            (encodings.isEmpty || encodings == ["chunked"])
    }

    func curl(original: Bool = false) -> String? {
        guard canCopyCurl else { return nil }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl --disable --globoff --path-as-is -X " + quote(method) + " " + quote(url)]
        if method == "HEAD" { parts.append("--head") }
        if requestTarget == "*" { parts.append("--request-target '*'") }
        let omitted = Set(["content-length", "transfer-encoding", "connection", "proxy-connection", "proxy-authorization", "expect", "keep-alive", "trailer", "te", "upgrade"])
        for header in original ? originalRequestHeaders : requestHeaders where !omitted.contains(header.name.lowercased()) {
            parts.append("-H " + quote(header.name + (header.value.isEmpty ? ";" : ": " + header.value)))
        }
        if !requestBody.isEmpty {
            if requestBody.count <= 32_768, let text = String(data: requestBody, encoding: .utf8), !text.contains("\0"), !text.hasPrefix("@") {
                parts.append("--data-binary " + quote(text))
            } else {
                // Base64 carries binary/NUL payloads exactly; no local file is required.
                let prefix = "printf '%s' " + quote(requestBody.base64EncodedString()) + " | /usr/bin/base64 -D | "
                parts.append("--data-binary @-")
                return prefix + parts.joined(separator: " \\\n  ")
            }
        }
        return parts.joined(separator: " \\\n  ")
    }
}

/// Structural identity uses separate host/path fields, avoiding collisions from URL delimiters.
struct CustomsRequestTreeNode: Identifiable {
    struct ID: Hashable {
        let host: String
        let path: String?
        var transactionID: UUID? = nil
    }
    let host: String
    let path: String?
    let count: Int
    var children: [CustomsRequestTreeNode]? = nil
    var transaction: CustomsTransaction? = nil
    var id: ID { ID(host: host, path: path, transactionID: transaction?.id) }
}

enum CustomsProxyEvent: Sendable {
    case started
    case stopped
    case transaction(CustomsTransaction)
    case failed(String)
}
