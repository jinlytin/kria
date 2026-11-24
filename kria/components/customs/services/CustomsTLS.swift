import Foundation
import Security
import Darwin

private nonisolated func customsTLSRead(_ connection: SSLConnectionRef, _ data: UnsafeMutableRawPointer,
                                       _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let socket = Unmanaged<CustomsSocket>.fromOpaque(connection).takeUnretainedValue()
    let requested = length.pointee
    length.pointee = 0
    let count = socket.tlsRead(data, count: requested)
    if count == 0 { return errSSLClosedNoNotify }
    if count < 0 { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? errSSLWouldBlock : errSSLClosedAbort }
    length.pointee = count
    return count == requested ? noErr : errSSLWouldBlock
}
private nonisolated func customsTLSWrite(_ connection: SSLConnectionRef, _ data: UnsafeRawPointer,
                                        _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let socket = Unmanaged<CustomsSocket>.fromOpaque(connection).takeUnretainedValue()
    let count = length.pointee
    let written = socket.tlsWrite(data, count: count)
    length.pointee = max(0, written)
    if written < 0 { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? errSSLWouldBlock : errSSLClosedAbort }
    return written == count ? noErr : errSSLWouldBlock
}

/// SSLContext is serialized, but polling occurs outside the lock: one upload writer and
/// one response reader can make progress concurrently on the same HTTP/1.1 connection.
nonisolated final class CustomsTLSTransport: CustomsTransport, @unchecked Sendable {
    let socket: CustomsSocket
    private let context: SSLContext
    private let ioLock = NSLock()
    private let host: String
    private let upstream: Bool
    // Explicit private anchors are dependency-injected for isolated local TLS tests.
    // Production proxy initialization leaves this nil and evaluates system trust.
    private let trustAnchors: [SecCertificate]?
    init(socket: CustomsSocket, host: String, identity: SecIdentity? = nil, trustAnchors: [SecCertificate]? = nil) throws {
        self.socket = socket; self.host = host; upstream = identity == nil
        self.trustAnchors = trustAnchors
        guard let context = SSLCreateContext(nil, identity == nil ? .clientSide : .serverSide, .streamType) else {
            throw CustomsBackendError.message("不能创建 SecureTransport TLS 上下文")
        }
        self.context = context
        try check(SSLSetIOFuncs(context, customsTLSRead, customsTLSWrite))
        try check(SSLSetConnection(context, Unmanaged.passUnretained(socket).toOpaque()))
        try check(SSLSetProtocolVersionMin(context, .tlsProtocol12))
        try check(SSLSetALPNProtocols(context, ["http/1.1"] as CFArray))
        if let identity {
            try check(SSLSetCertificate(context, [identity] as CFArray))
        } else {
            try host.utf8CString.withUnsafeBufferPointer {
                try check(SSLSetPeerDomainName(context, $0.baseAddress!, $0.count - 1))
            }
            try check(SSLSetSessionOption(context, .breakOnServerAuth, true))
        }
    }
    private func check(_ status: OSStatus, line: Int = #line) throws {
        guard status == noErr else {
            throw CustomsBackendError.message("\(failure(status).localizedDescription) [TLS:\(line), OSStatus \(status)]")
        }
    }
    private func failure(_ status: OSStatus) -> CustomsBackendError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        let io = socket.tlsIOFailureDescription.map { "；\($0)" } ?? ""
        return .message(upstream
            ? "上游 TLS \(host) 失败: \(message)\(io)。检查源站网络、TLS 兼容性与证书；与客户端信任代理 CA 无关，不会跳过源站证书校验。"
            : "客户端 TLS \(host) 失败: \(message)\(io)。可能是客户端中止、CA 信任问题或 App 证书绑定；仅凭断开/重置不能确认 CA 未信任。若浏览器成功而某 App 失败，请检查该 App 的证书绑定策略。")
    }
    private func wait(_ events: Int16, deadline: Date) throws {
        do { try socket.wait(events, deadline: deadline) }
        catch {
            throw CustomsBackendError.message("\(upstream ? "上游" : "客户端") TLS \(host) 等待失败：\(error.localizedDescription)")
        }
    }
    func handshake() throws {
        let deadline = Date().addingTimeInterval(30)
        var validated = !upstream
        while true {
            guard deadline.timeIntervalSinceNow > 0 else { throw CustomsBackendError.message("\(upstream ? "上游" : "客户端") TLS \(host) 握手超时") }
            let status = SSLHandshake(context)
            if status == errSSLPeerAuthCompleted && upstream {
                var trust: SecTrust?
                try check(SSLCopyPeerTrust(context, &trust))
                guard let trust else { throw CustomsBackendError.message("上游 \(host) 未提供证书链") }
                try check(SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)))
                if let trustAnchors {
                    try check(SecTrustSetAnchorCertificates(trust, trustAnchors as CFArray))
                    try check(SecTrustSetAnchorCertificatesOnly(trust, true))
                }
                var error: CFError?
                guard SecTrustEvaluateWithError(trust, &error) else {
                    throw CustomsBackendError.message("上游 TLS 证书校验失败（\(host)）: \(error.map { String(describing: $0) } ?? "证书不受信任")。请修复服务端证书/系统信任链；代理不会绕过校验。")
                }
                validated = true; continue
            }
            if status == errSSLWouldBlock { try wait(Int16(POLLIN), deadline: deadline); continue }
            try check(status)
            guard validated else { throw CustomsBackendError.message("上游 TLS 未完成证书校验") }
            // SSLSetALPNProtocols advertises only http/1.1 on each side. Do not use
            // SSLCopyALPNProtocols: current macOS returns errSecParam even with a nil
            // output pointer after successful local handshakes. HTTP parsing below
            // independently rejects HTTP/2 prefaces and all non-HTTP/1.x traffic.
            return
        }
    }
    func read(maximum: Int) throws -> Data {
        var data = Data(count: maximum)
        var processed = 0
        let deadline = Date().addingTimeInterval(CustomsSocket.ioTimeout)
        while true {
            ioLock.lock()
            let status = data.withUnsafeMutableBytes { SSLRead(context, $0.baseAddress!, maximum, &processed) }
            ioLock.unlock()
            if processed > 0 { data.count = processed; return data }
            if status == errSSLClosedGraceful { return Data() }
            // An unclean TLS EOF must not delimit a response: it could be a truncation attack.
            if status == errSSLWouldBlock { try wait(Int16(POLLIN), deadline: deadline); continue }
            try check(status)
            throw CustomsBackendError.message("TLS 读取没有进展")
        }
    }
    func closeGracefully() {
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            ioLock.lock()
            let status = SSLClose(context)
            ioLock.unlock()
            guard status == errSSLWouldBlock else { return }
            // Flush close_notify, but do not wait for the peer's reply or hold
            // the SSLContext lock while polling. Cancellation wakes this wait.
            do { try socket.wait(Int16(POLLOUT), deadline: deadline) }
            catch { return }
        } while deadline.timeIntervalSinceNow > 0
    }
    func write(_ data: Data) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(CustomsSocket.ioTimeout)
        while offset < data.count {
            var processed = 0
            ioLock.lock()
            let status = data.withUnsafeBytes { SSLWrite(context, $0.baseAddress!.advanced(by: offset), data.count - offset, &processed) }
            ioLock.unlock()
            offset += processed
            if status == errSSLWouldBlock { try wait(Int16(POLLOUT), deadline: deadline); continue }
            try check(status)
            guard processed > 0 else { throw CustomsBackendError.message("TLS 写入没有进展") }
        }
    }
}
