import Foundation
import Darwin
import Security
import CryptoKit

nonisolated struct CustomsCertificateDownloadSession: Sendable, Equatable {
    let port: UInt16
    let expiresAt: Date
    let token: String
    let addresses: [String]
    /// SHA-256 of the actual DER, not caller-supplied display text.
    let fingerprint: String?
    var urls: [String] { addresses.map { "http://\($0):\(port)/\(token)/" } }
}

/// A manually started public-certificate endpoint; independent of proxy configuration.
nonisolated final class CustomsCertificateDownloadServer: @unchecked Sendable {
    static let maximumClients = 8
    static let headerLimit = 8 * 1024
    static let connectionTimeout: TimeInterval = 30
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "kria.customs.certificate-download", qos: .utility)
    // Shared across generations: rapid restarts cannot create unbounded workers.
    private let slots = DispatchSemaphore(value: maximumClients)
    private let addressProvider: @Sendable () -> [String]
    private var current: Run?

    private final class Run: @unchecked Sendable {
        let id = UUID()
        let listener: CustomsSocket
        let session: CustomsCertificateDownloadSession
        let certificate: Data
        let source: DispatchSourceRead
        let timer: DispatchSourceTimer
        var clients: [UUID: CustomsSocket] = [:] // guarded by server lock
        init(listener: CustomsSocket, session: CustomsCertificateDownloadSession,
             certificate: Data, queue: DispatchQueue) {
            self.listener = listener; self.session = session; self.certificate = certificate
            source = DispatchSource.makeReadSource(fileDescriptor: listener.descriptor, queue: queue)
            timer = DispatchSource.makeTimerSource(queue: queue)
        }
        func cancel() {
            source.cancel(); timer.cancel(); listener.cancel()
            for socket in clients.values { socket.cancel() }
            clients.removeAll()
        }
    }

    init() { addressProvider = { Self.localIPv4Addresses() } }
    /// Injectable without touching any system network or proxy settings.
    init(localAddressProvider: @escaping @Sendable () -> [String]) {
        addressProvider = localAddressProvider
    }
    deinit { current?.cancel() }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return current.map { $0.session.expiresAt > Date() } ?? false
    }

    /// Replaces an existing session only after validation and binding succeed.
    /// fingerprint is retained for API compatibility, bounded, but never trusted/embedded.
    func start(certificateDER: Data, fingerprint: String, listenOnLAN: Bool = true,
               duration: TimeInterval = 600) throws -> CustomsCertificateDownloadSession {
        guard Self.isSingleDERSequence(certificateDER), certificateDER.count <= 1024 * 1024,
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              SecCertificateCopyData(certificate) as Data == certificateDER else {
            throw CustomsBackendError.message("下载服务只接受单个有效 DER 公钥证书，不接受 PEM、私钥或附加数据")
        }
        guard fingerprint.utf8.count <= 256 else {
            throw CustomsBackendError.message("证书指纹参数超过 256 字节")
        }
        guard duration.isFinite, duration > 0, duration <= 86400 else {
            throw CustomsBackendError.message("下载有效期必须大于 0 且不超过 86400 秒")
        }
        lock.lock(); defer { lock.unlock() }
        let addresses = listenOnLAN ? Self.normalizedAddresses(addressProvider()) : ["127.0.0.1"]
        guard !addresses.isEmpty else {
            throw CustomsBackendError.message("当前没有已启用的非回环 IPv4 网络地址；请连接 Wi-Fi 或有线网络后重新开启证书下载")
        }
        let listener = try CustomsSocket.listen(port: 0, lan: listenOnLAN)
        guard listener.localPort != 0 else {
            listener.cancel(); throw CustomsBackendError.message("无法获取证书下载服务的临时监听端口")
        }
        let digest = SHA256.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined()
        let session = CustomsCertificateDownloadSession(port: listener.localPort,
            expiresAt: Date().addingTimeInterval(duration), token: UUID().uuidString.lowercased(),
            addresses: addresses, fingerprint: digest)
        let run = Run(listener: listener, session: session, certificate: certificateDER, queue: queue)
        run.source.setEventHandler { [weak self, weak run] in
            guard let self, let run else { return }
            self.accept(run)
        }
        // Keep the descriptor alive until dispatch has finished unregistering it.
        run.source.setCancelHandler { [listener] in listener.cancel() }
        run.timer.schedule(deadline: .now() + duration)
        run.timer.setEventHandler { [weak self, weak run] in
            guard let run else { return }
            self?.stop(generation: run.id)
        }
        current?.cancel(); current = run
        run.source.resume(); run.timer.resume()
        return session
    }

    func stop() { stop(generation: nil) }
    private func stop(generation: UUID?) {
        lock.lock(); defer { lock.unlock() }
        guard let run = current, generation == nil || generation == run.id else { return }
        current = nil; run.cancel()
    }

    private func accept(_ run: Run) {
        // Bounded accept work also leaves the serial queue free to deliver expiry.
        for _ in 0..<16 {
            lock.lock()
            guard current?.id == run.id, Date() < run.session.expiresAt else {
                lock.unlock(); stop(generation: run.id); return
            }
            let socket: CustomsSocket
            do {
                guard let accepted = try run.listener.acceptClient() else { lock.unlock(); return }
                socket = accepted
            } catch { lock.unlock(); stop(generation: run.id); return }
            guard slots.wait(timeout: .now()) == .success else {
                socket.cancel(); lock.unlock(); continue
            }
            let id = UUID(); run.clients[id] = socket
            lock.unlock()
            let slots = self.slots
            DispatchQueue.global(qos: .utility).async { [weak self, run, socket] in
                defer {
                    socket.cancel()
                    self?.removeClient(id, from: run)
                    slots.signal()
                }
                Self.serve(socket, run: run)
            }
        }
    }
    private func removeClient(_ id: UUID, from run: Run) {
        lock.lock(); defer { lock.unlock() }
        run.clients.removeValue(forKey: id)
    }

    private enum RequestError: Error { case tooLarge }
    /// Bounds bytes *before* CustomsHTTPReader buffers/parses the complete head.
    private final class HeaderTransport: CustomsTransport, @unchecked Sendable {
        let plain: CustomsPlainTransport
        private var remaining = headerLimit
        private var tail: UInt32 = 0
        private var complete = false
        init(_ socket: CustomsSocket) { plain = CustomsPlainTransport(socket) }
        func read(maximum: Int) throws -> Data {
            guard remaining > 0 || complete else { throw RequestError.tooLarge }
            let data = try plain.read(maximum: min(maximum, complete ? 1024 : min(remaining, 1024)))
            if !complete {
                for byte in data {
                    remaining -= 1; tail = (tail << 8) | UInt32(byte)
                    if tail == 0x0D0A0D0A { complete = true; break }
                }
            }
            return data
        }
        func write(_ data: Data) throws { try plain.write(data) }
    }

    private static func serve(_ socket: CustomsSocket, run: Run) {
        // Absolute connection deadline, including slow/drip-fed headers and writes.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + connectionTimeout)
        timer.setEventHandler { [weak socket] in socket?.cancel() }
        timer.resume(); defer { timer.cancel() }
        let transport = HeaderTransport(socket)
        var isHead = false
        do {
            let head = try CustomsHTTPReader(transport).head()
            let parts = head.firstLine.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, CustomsHTTP.validName(String(parts[0])),
                  parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1",
                  parts[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                try respond(transport, status: "400 Bad Request"); return
            }
            let method = String(parts[0]), path = String(parts[1])
            isHead = method == "HEAD"
            guard method == "GET" || isHead else {
                try respond(transport, status: "405 Method Not Allowed", extra: "Allow: GET, HEAD\r\n"); return
            }
            guard Date() < run.session.expiresAt, !socket.isCancelled else { return }
            let prefix = "/\(run.session.token)/"
            // Exact raw-path matching: queries, encoded paths, traversal and absolute URLs are 404.
            if path == prefix {
                let html = """
                <!doctype html><html lang="zh-CN"><meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>海关 CA 证书安装</title><body><h1>海关 CA 证书安装</h1>
                <p>仅下载公钥 CA 证书，不含私钥。请只在自己信任的调试设备上安装。</p>
                <p><a href="\(prefix)KriaCustomsCA.cer">下载 KriaCustomsCA.cer</a></p>
                <p>SHA-256 指纹：<code>\(escapeHTML(run.session.fingerprint ?? ""))</code></p>
                <ol><li>先与 Mac 海关显示的指纹核对，再下载并安装。</li>
                <li>iPhone / iPad：在设置中安装已下载的描述文件，然后在「通用 → 关于本机 → 证书信任设置」启用该 CA 的完全信任。</li>
                <li>Android：在设置的安全/证书安装中选择 CA 证书；部分应用不信任用户安装的 CA。</li>
                <li>返回 Mac「海关」查看实际代理 IP 和端口（默认 8888），在手机 Wi-Fi 设置中手动配置 HTTP 代理，并且必须在海关允许代理 LAN 访问。</li></ol>
                <p>本页临时下载端口不是代理端口；能下载证书不代表代理已允许 LAN。手机与 Mac 应在同一可互通网络。</p>
                <p>调试完成后关闭手机代理，撤销信任并移除证书。下载链接到期自动关闭。</p>
                </body></html>
                """
                try respond(transport, status: "200 OK", body: Data(html.utf8),
                            contentType: "text/html; charset=utf-8", head: isHead)
            } else if path == prefix + "KriaCustomsCA.cer" {
                try respond(transport, status: "200 OK", body: run.certificate,
                            contentType: "application/x-x509-ca-cert", head: isHead,
                            extra: "Content-Disposition: attachment; filename=\"KriaCustomsCA.cer\"\r\n")
            } else {
                try respond(transport, status: "404 Not Found", head: isHead)
            }
        } catch RequestError.tooLarge {
            try? respond(transport, status: "431 Request Header Fields Too Large", head: isHead)
        } catch {
            try? respond(transport, status: "400 Bad Request", head: isHead)
        }
    }
    private static func respond(_ transport: any CustomsTransport, status: String, body: Data = Data(),
                                contentType: String = "text/plain; charset=utf-8", head: Bool = false,
                                extra: String = "") throws {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Security-Policy: default-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n\(extra)\r\n"
        try transport.write(Data(headers.utf8))
        if !head && !body.isEmpty { try transport.write(body) }
    }
    private static func isSingleDERSequence(_ data: Data) -> Bool {
        guard data.count >= 2, data.count <= 1024 * 1024 else { return false }
        let bytes = Array(data.prefix(6))
        guard bytes[0] == 0x30 else { return false }
        if bytes[1] < 0x80 { return Int(bytes[1]) + 2 == data.count }
        let count = Int(bytes[1] & 0x7f)
        guard (1...4).contains(count), bytes.count >= count + 2, bytes[2] != 0 else { return false }
        let length = bytes[2..<(count + 2)].reduce(0) { $0 * 256 + Int($1) }
        return length >= 128 && length + count + 2 == data.count
    }
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Fresh interface snapshot on every call; no DNS, external requests or cached settings.
    public static func localIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { if let list { freeifaddrs(list) } }
        var addresses: [String] = [], cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil {
                addresses.append(String(cString: buffer))
            }
        }
        return normalizedAddresses(addresses)
    }
    private static func normalizedAddresses(_ addresses: [String]) -> [String] {
        var unique = Set<String>()
        for text in addresses {
            var ip = in_addr()
            guard inet_pton(AF_INET, text, &ip) == 1 else { continue }
            let value = UInt32(bigEndian: ip.s_addr), first = value >> 24
            guard first != 0, first != 127, first < 224 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil {
                unique.insert(String(cString: buffer))
            }
        }
        func isPrivate(_ text: String) -> Bool {
            let octets = text.split(separator: ".").compactMap { Int($0) }
            return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168)
        }
        return unique.sorted {
            if isPrivate($0) != isPrivate($1) { return isPrivate($0) }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}
