import Foundation
import Darwin
import Security

nonisolated final class CustomsProxyServer: @unchecked Sendable {
    static let maximumConnections = 64
    private let lock = NSLock()
    private let eventQueue = DispatchQueue(label: "Kria.Customs.events")
    private let onEvent: @Sendable (CustomsProxyEvent) -> Void
    private var listener: CustomsSocket?
    private var sessions: [UUID: Session] = [:]
    private var generation = UUID()
    private var rules: [CustomsHeaderRule] = []
    private var rewriteEnabled = false
    private var recording = true
    private let certificateAuthority: CustomsCertificateAuthority
    private let upstreamTrustAnchors: [SecCertificate]?
    /// nil anchors use the system trust store. Explicit anchors are for isolated tests;
    /// even with anchors, certificate validity and hostname are always evaluated.
    init(certificateAuthority: CustomsCertificateAuthority = .shared,
         upstreamTrustAnchors: [SecCertificate]? = nil,
         onEvent: @escaping @Sendable (CustomsProxyEvent) -> Void) {
        self.certificateAuthority = certificateAuthority
        self.upstreamTrustAnchors = upstreamTrustAnchors
        self.onEvent = onEvent
    }
    deinit { stop() }
    func start(configuration: CustomsProxyConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { throw CustomsBackendError.message("代理已经启动") }
        let socket = try CustomsSocket.listen(port: configuration.port, lan: configuration.listenOnLAN)
        CustomsSocket.refreshDNSCache()
        listener = socket; generation = UUID()
        let token = generation
        rules = configuration.headerRules; rewriteEnabled = configuration.rewriteEnabled
        // Bind synchronously to report port errors, but all certificate work stays off the caller/UI thread.
        let authority = certificateAuthority
        DispatchQueue.global(qos: .userInitiated).async { [weak self, socket] in
            do {
                if configuration.decryptHTTPS { try authority.prepare() }
                guard let self, self.isActive(token) else { return }
                self.lock.lock()
                let active = self.generation == token && self.listener != nil
                if active { self.emit(.started) }
                self.lock.unlock()
                if active { self.acceptLoop(socket, configuration: configuration, token: token) }
            } catch {
                self?.failStart(error, token: token)
            }
        }
    }
    func stop() {
        lock.lock()
        let socket = listener; let active = Array(sessions.values)
        listener = nil; sessions.removeAll(); generation = UUID()
        lock.unlock()
        socket?.cancel(); active.forEach { $0.cancel() }
        if socket != nil { emit(.stopped) }
    }
    func updateRules(_ rules: [CustomsHeaderRule], enabled: Bool) {
        lock.lock(); self.rules = rules; rewriteEnabled = enabled; lock.unlock()
    }
    func setRecording(_ enabled: Bool) { lock.lock(); recording = enabled; lock.unlock() }
    private func emit(_ event: CustomsProxyEvent) {
        let callback = onEvent
        eventQueue.async { callback(event) }
    }
    private func isActive(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return listener != nil && generation == token
    }
    private func failStart(_ error: Error, token: UUID) {
        lock.lock()
        guard generation == token else { lock.unlock(); return }
        let socket = listener; listener = nil; generation = UUID()
        let active = Array(sessions.values); sessions.removeAll(); lock.unlock()
        socket?.cancel(); active.forEach { $0.cancel() }
        emit(.failed(error.localizedDescription)); emit(.stopped)
    }
    private func acceptLoop(_ socket: CustomsSocket, configuration: CustomsProxyConfiguration, token: UUID) {
        while isActive(token) {
            do {
                // Poll timeouts are only an idle wake-up, not listener failures.
                do { try socket.wait(Int16(POLLIN), deadline: Date().addingTimeInterval(1)) }
                catch { if !isActive(token) { return }; continue }
                guard let client = try socket.acceptClient() else { continue }
                let session = Session(client: client)
                lock.lock()
                let admitted = generation == token && listener != nil && sessions.count < Self.maximumConnections
                if admitted { sessions[session.id] = session }
                lock.unlock()
                guard admitted else {
                    // Never block the accept loop writing to a slow client.
                    client.cancel(); continue
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { session.cancel(); return }
                    self.serve(session, configuration: configuration, proxyPort: socket.localPort)
                    session.cancel()
                    self.lock.lock(); self.sessions.removeValue(forKey: session.id); self.lock.unlock()
                }
            } catch { if isActive(token) { failStart(error, token: token) }; return }
        }
    }
    private func policy() -> ([CustomsHeaderRule], Bool, Bool) {
        lock.lock(); defer { lock.unlock() }; return (rules, rewriteEnabled, recording)
    }
    private func record(_ transaction: CustomsTransaction, enabled: Bool) {
        guard enabled else { return }
        // Recording is snapshotted at request receipt. Pausing only suppresses new
        // transactions, not final updates of ones already visible in the UI.
        emit(.transaction(transaction))
    }
    private func record(_ state: TransactionState, enabled: Bool) {
        state.publish { record($0, enabled: enabled) }
    }
    private func phase(_ next: CustomsRequestPhase, state: TransactionState, enabled: Bool) {
        state.publish(update: { $0.advance(to: next) }) { record($0, enabled: enabled) }
    }
    private func connect(_ destination: CustomsHTTP.Destination, session: Session, proxyPort: UInt16,
                         state: TransactionState, enabled: Bool) throws -> CustomsSocket {
        try CustomsSocket.connect(host: destination.host, port: destination.port, proxyPort: proxyPort,
                                  isCancelled: { session.client.isCancelled }, onPhase: { next in
            self.phase(next == .dns ? .dns : .connecting, state: state, enabled: enabled)
        }) { try session.add($0) }
    }
    private func serve(_ session: Session, configuration: CustomsProxyConfiguration, proxyPort: UInt16) {
        let plain = CustomsPlainTransport(session.client)
        var client: any CustomsTransport = plain
        var reader = CustomsHTTPReader(plain)
        var transaction: TransactionState?
        var recordEnabled = false
        var responseStarted = false
        let uploadDone = DispatchGroup()
        defer {
            // Keep the client writable through catch so a local error can be delivered.
            (client as? CustomsTLSTransport)?.closeGracefully()
            session.cancel(); uploadDone.wait()
        }
        do {
            var head = try reader.head()
            var destination = try CustomsHTTP.destination(head)
            recordEnabled = policy().2
            let initialUpgrade = !head.values("upgrade").isEmpty || head.tokens("connection").contains("upgrade")
            var initial = CustomsTransaction(method: destination.method, url: destination.url)
            initial.originalRequestHeaders = head.headers; initial.requestHeaders = head.headers
            initial.requestTarget = destination.target
            initial.isTunnel = destination.method == "CONNECT" || initialUpgrade
            if destination.method == "CONNECT" {
                initial.httpsHandling = !configuration.decryptHTTPS ? .disabled :
                    (CustomsHTTP.matches(destination.host, patterns: configuration.sslHosts) ? .decrypting : .hostExcluded)
            }
            let state = TransactionState(initial); transaction = state
            if destination.method != "CONNECT" {
                let framing = try CustomsHTTP.framing(head)
                if framing == .none || framing == .length(0) { state.markUploadComplete() }
            }
            record(state, enabled: recordEnabled)
            let recordEnabledForConnect = recordEnabled
            var upstream: any CustomsTransport
            if destination.method == "CONNECT" {
                guard try CustomsHTTP.framing(head) == .none || CustomsHTTP.framing(head) == .length(0) else {
                    throw CustomsBackendError.message("CONNECT 不允许 request body")
                }
                let remote = try connect(destination, session: session, proxyPort: proxyPort, state: state, enabled: recordEnabled)
                if initial.httpsHandling == .decrypting {
                    // Never silently fall back to a tunnel after a certificate/MITM failure.
                    phase(.certificate, state: state, enabled: recordEnabled)
                    let identity = try certificateAuthority.identity(for: destination.host)
                    phase(.upstreamTLS, state: state, enabled: recordEnabled)
                    let tlsRemote = try CustomsTLSTransport(socket: remote, host: destination.host, trustAnchors: upstreamTrustAnchors)
                    try tlsRemote.handshake()
                    // CONNECT must not overread a pipelined ClientHello into the HTTP buffer.
                    guard reader.buffered.isEmpty else { throw CustomsBackendError.message("MITM CONNECT 不支持提前发送 TLS ClientHello；请等待 200") }
                    responseStarted = true
                    try plain.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                    state.mutate { $0.statusCode = 200 }
                    record(state, enabled: recordEnabled)
                    let tlsClient = try CustomsTLSTransport(socket: session.client, host: destination.host, identity: identity)
                    client = tlsClient
                    phase(.clientTLS, state: state, enabled: recordEnabled)
                    try tlsClient.handshake()
                    phase(.clientRequest, state: state, enabled: recordEnabled)
                    reader = CustomsHTTPReader(tlsClient)
                    head = try reader.head()
                    destination = try CustomsHTTP.destination(head, tunnel: (destination.host, destination.port))
                    // Decrypted HTTP is a new request, with its own recording decision.
                    recordEnabled = policy().2
                    var request = CustomsTransaction(method: destination.method, url: destination.url)
                    request.originalRequestHeaders = head.headers; request.requestHeaders = head.headers
                    request.requestTarget = destination.target
                    request.httpsHandling = .decrypting
                    request.relatedTransactionID = recordEnabledForConnect ? initial.id : nil
                    request.isTunnel = !head.values("upgrade").isEmpty || head.tokens("connection").contains("upgrade")
                    // Finish the CONNECT ID exactly once before handing state to HTTP.
                    state.mutate {
                        $0.relatedTransactionID = recordEnabled ? request.id : nil
                        $0.finishTiming()
                    }
                    record(state, enabled: recordEnabledForConnect)
                    state.replace(request)
                    // CONNECT's 200 is not the final response to this decrypted request.
                    responseStarted = false
                    let framing = try CustomsHTTP.framing(head)
                    if framing == .none || framing == .length(0) { state.markUploadComplete() }
                    record(state, enabled: recordEnabled)
                    upstream = tlsRemote
                } else {
                    responseStarted = true
                    try plain.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                    state.mutate { $0.statusCode = 200 }
                    record(state, enabled: recordEnabled)
                    let remoteTransport = CustomsPlainTransport(remote)
                    try remoteTransport.write(reader.takeBuffered())
                    phase(.tunnel, state: state, enabled: recordEnabled)
                    try tunnel(plain, remoteTransport, session: session)
                    state.mutate { $0.finishTiming() }; record(state, enabled: recordEnabled)
                    return
                }
            } else {
                let remote = try connect(destination, session: session, proxyPort: proxyPort, state: state, enabled: recordEnabled)
                upstream = CustomsPlainTransport(remote)
            }
            guard head.values("upgrade").isEmpty && !head.tokens("connection").contains("upgrade") else {
                state.mutate { $0.isTunnel = true; $0.rewrittenHeaders = [] }
                throw CustomsBackendError.message("不支持 WebSocket/HTTP Upgrade；不会改写此连接。请使用不解密的 CONNECT 隧道。")
            }
            let requestFraming = try CustomsHTTP.framing(head)
            let expectations = head.tokens("expect")
            guard expectations.isEmpty || expectations == ["100-continue"] else { throw CustomsBackendError.message("不支持此 Expect header") }
            let (rules, enabled, _) = policy()
            let rewritten = head.rewrite(rules: rules, enabled: enabled)
            head.firstLine = "\(destination.method) \(destination.target) \(destination.version)"
            // Only hop-by-hop proxy credentials/connection disposition are normalized.
            head.fields.removeAll { ["proxy-authorization", "proxy-connection", "connection", "expect"].contains($0.name.lowercased()) }
            head.fields.append(.init(name: "Connection", value: "close", wire: Data("Connection: close".utf8)))
            state.mutate { $0.requestHeaders = head.headers; $0.rewrittenHeaders = rewritten }
            record(state, enabled: recordEnabled)
            // Own Expect handling locally: an origin may wait for the entire body
            // without ever sending 100. No timeout/retry or second response reader.
            let sentContinue = !expectations.isEmpty && requestFraming != .none && requestFraming != .length(0)
            if sentContinue {
                try client.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                // An interim response does not prohibit a later local final error.
            }
            phase(.sendingRequest, state: state, enabled: recordEnabled)
            try upstream.write(head.wire)
            let responseReader = CustomsHTTPReader(upstream)
            if requestFraming != .none && requestFraming != .length(0) {
                uploadDone.enter()
                let uploadReader = reader
                let uploadTransport = upstream
                let uploadRecording = recordEnabled
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { uploadDone.leave() }
                    do {
                        var lastUploadEvent = Date.distantPast
                        try uploadReader.forward(requestFraming, to: uploadTransport) { data in
                            state.capture(data, response: false)
                            if Date().timeIntervalSince(lastUploadEvent) >= 0.15 {
                                self.record(state, enabled: uploadRecording); lastUploadEvent = Date()
                            }
                        }
                        state.markUploadComplete { self.record($0, enabled: uploadRecording) }
                    } catch {
                        state.failUpload(error) { session.cancelUpstreams() }
                    }
                }
            }
            if requestFraming == .none || requestFraming == .length(0) {
                phase(.waitingResponse, state: state, enabled: recordEnabled)
            }
            var response: CustomsHTTP.Head?
            var interimCount = 0
            while response == nil {
                let candidate = try responseReader.head()
                guard let status = candidate.status else { throw CustomsBackendError.message("非法响应状态行") }
                if status >= 200 { try state.markFinalResponse(); response = candidate; break }
                interimCount += 1
                guard status != 101, interimCount <= 32 else { throw CustomsBackendError.message("不支持 Upgrade 或过多 interim responses") }
                _ = try CustomsHTTP.framing(candidate, responseTo: destination.method)
                if status != 100 || !sentContinue { try client.write(candidate.wire) }
            }
            guard var response else { throw CustomsBackendError.message("缺少响应") }
            let responseFraming = try CustomsHTTP.framing(response, responseTo: destination.method)
            response.fields.removeAll { ["connection", "proxy-connection"].contains($0.name.lowercased()) }
            response.fields.append(.init(name: "Connection", value: "close", wire: Data("Connection: close".utf8)))
            state.mutate {
                $0.responseHeaders = response.headers; $0.statusCode = response.status
                $0.advance(to: .receivingResponse)
            }
            record(state, enabled: recordEnabled)
            // A partial header write must never be followed by a second HTTP response.
            responseStarted = true
            try client.write(response.wire)
            var lastEvent = Date()
            try responseReader.forward(responseFraming, to: client) { data in
                state.capture(data, response: true)
                if Date().timeIntervalSince(lastEvent) >= 0.15 {
                    record(state, enabled: recordEnabled); lastEvent = Date()
                }
            }
            (client as? CustomsTLSTransport)?.closeGracefully()
            session.cancel(); uploadDone.wait()
            state.finish()
            record(state, enabled: recordEnabled)
        } catch {
            if transaction == nil && !session.client.isCancelled {
                // A malformed client is not a server lifecycle failure.
                transaction = TransactionState(CustomsTransaction(method: "INVALID", url: "http://invalid-request/"))
                recordEnabled = policy().2
            }
            let snapshot = transaction?.snapshot()
            let underlying = snapshot?.error ?? error.localizedDescription
            let failure: String
            if let snapshot, snapshot.method == "CONNECT" {
                failure = "CONNECT \(snapshot.host) · \(snapshot.phase.title)失败：\(underlying)"
            } else {
                failure = underlying
            }
            transaction?.mutate { $0.error = failure }
            if !responseStarted && !session.client.isCancelled {
                let diagnostic = Data(failure.utf8)
                let status = failure.contains("不支持") ? "501 Not Implemented" : "502 Bad Gateway"
                let fields = [
                    CustomsHTTP.Field(name: "Content-Type", value: "text/plain; charset=utf-8", wire: Data("Content-Type: text/plain; charset=utf-8".utf8)),
                    CustomsHTTP.Field(name: "Content-Length", value: "\(diagnostic.count)", wire: Data("Content-Length: \(diagnostic.count)".utf8)),
                    CustomsHTTP.Field(name: "Connection", value: "close", wire: Data("Connection: close".utf8))
                ]
                let response = CustomsHTTP.Head(firstLine: "HTTP/1.1 \(status)", fields: fields)
                // HEAD describes the diagnostic representation without sending its body.
                let body = transaction?.snapshot().method == "HEAD" ? Data() : diagnostic
                do {
                    responseStarted = true
                    try client.write(response.wire + body)
                    transaction?.mutate {
                        $0.statusCode = response.status; $0.responseHeaders = response.headers
                        $0.responseBody = Data(body.prefix(CustomsHTTP.captureLimit))
                        $0.responseByteCount = body.count
                        $0.responseBodyTruncated = body.count > CustomsHTTP.captureLimit
                        $0.responseIsLocal = true
                    }
                } catch { /* The original failure remains visible if the peer cannot receive the diagnostic. */ }
            }
            // Wake and join any pending upload only AFTER sending the error/close_notify.
            // Finish once, after capture workers stop mutating this transaction.
            (client as? CustomsTLSTransport)?.closeGracefully()
            session.cancel(); uploadDone.wait()
            if let transaction {
                transaction.mutate { $0.error = failure }
                transaction.finish()
                record(transaction, enabled: recordEnabled)
            }
        }
    }
    private func tunnel(_ client: CustomsPlainTransport, _ remote: CustomsPlainTransport, session: Session) throws {
        let group = DispatchGroup()
        let result = TunnelResult()
        for (source, destination, sourceName, destinationName) in [
            (client, remote, "客户端", "上游"), (remote, client, "上游", "客户端")
        ] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                do {
                    while true {
                        let data: Data
                        do { data = try source.read() }
                        catch { throw CustomsBackendError.message("读取\(sourceName)失败：\(error.localizedDescription)") }
                        if data.isEmpty { destination.socket.shutdownWrite(); break }
                        do { try destination.write(data) }
                        catch { throw CustomsBackendError.message("写入\(destinationName)失败：\(error.localizedDescription)") }
                    }
                } catch { result.set(error); session.cancel() }
            }
        }
        group.wait()
        if let error = result.error { throw error }
    }
    private final class TunnelResult: @unchecked Sendable {
        let lock = NSLock(); private var stored: Error?
        var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
    }
    private final class Session: @unchecked Sendable {
        let id = UUID(); let client: CustomsSocket
        let lock = NSLock(); var sockets: [CustomsSocket]; var cancelled = false
        init(client: CustomsSocket) { self.client = client; sockets = [client] }
        func add(_ socket: CustomsSocket) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { socket.cancel(); throw CustomsBackendError.message("代理已停止") }
            sockets.append(socket)
        }
        func cancelUpstreams() {
            lock.lock(); let active = sockets.filter { $0 !== client }; lock.unlock()
            active.forEach { $0.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let active = sockets; lock.unlock()
            active.forEach { $0.cancel() }
        }
    }
    private final class TransactionState: @unchecked Sendable {
        let lock = NSLock(); var value: CustomsTransaction; private var finalResponse = false
        private var uploadComplete = false
        init(_ value: CustomsTransaction) { self.value = value }
        func replace(_ value: CustomsTransaction) {
            lock.lock(); self.value = value; uploadComplete = false; finalResponse = false; lock.unlock()
        }
        func markUploadComplete(publish: ((CustomsTransaction) -> Void)? = nil) {
            lock.lock(); defer { lock.unlock() }
            uploadComplete = true; value.requestBodyComplete = true
            if value.phase == .sendingRequest { value.advance(to: .waitingResponse) }
            publish?(value)
        }
        // Snapshot creation and event enqueue share the state lock so concurrent
        // upload/response workers cannot publish an older snapshot after a newer one.
        func publish(update: (inout CustomsTransaction) -> Void = { _ in },
                     _ callback: (CustomsTransaction) -> Void) {
            lock.lock(); defer { lock.unlock() }
            update(&value); callback(value)
        }
        func finish() {
            lock.lock(); defer { lock.unlock() }
            value.requestBodyIncomplete = !uploadComplete && !value.isTunnel
            value.finishTiming()
        }
        func snapshot() -> CustomsTransaction { lock.lock(); defer { lock.unlock() }; return value }
        func mutate(_ body: (inout CustomsTransaction) -> Void) { lock.lock(); body(&value); lock.unlock() }
        func failUpload(_ error: Error, cancelUpstreams: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !finalResponse else { return }
            value.error = "上传失败: \(error.localizedDescription)"
            // Cancellation and claiming a final response are one serialized decision.
            // A stale upload failure must not cancel a response already being streamed.
            cancelUpstreams()
        }
        func markFinalResponse() throws {
            lock.lock(); defer { lock.unlock() }
            if let error = value.error { throw CustomsBackendError.message(error) }
            finalResponse = true
        }
        func capture(_ data: Data, response: Bool) {
            lock.lock(); defer { lock.unlock() }
            if response {
                value.responseByteCount += data.count
                let remaining = max(0, CustomsHTTP.captureLimit - value.responseBody.count)
                value.responseBody.append(data.prefix(remaining))
                if data.count > remaining { value.responseBodyTruncated = true }
            } else {
                let remaining = max(0, CustomsHTTP.captureLimit - value.requestBody.count)
                value.requestBody.append(data.prefix(remaining))
                if data.count > remaining { value.requestBodyTruncated = true }
            }
        }
    }
}
