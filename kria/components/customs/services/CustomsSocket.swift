import Foundation
import Darwin

nonisolated enum CustomsBackendError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
    static func system(_ operation: String) -> CustomsBackendError {
        .message("\(operation): \(String(cString: strerror(errno)))")
    }
}

/// Cancellation only shuts down the descriptor. It is closed at deinit, so an in-flight
/// poll/SSL callback cannot accidentally operate on a newly reused descriptor number.
nonisolated final class CustomsSocket: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var tlsIOFailure: (operation: String, code: Int32)?
    var tlsIOFailureDescription: String? {
        lock.lock(); defer { lock.unlock() }
        guard let failure = tlsIOFailure else { return nil }
        return "socket \(failure.operation)失败: \(String(cString: strerror(failure.code))) (errno=\(failure.code))"
    }
    static let ioTimeout: TimeInterval = 30
    init(_ descriptor: Int32) throws {
        var one: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            throw CustomsBackendError.system("配置 socket")
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        self.descriptor = descriptor
    }
    deinit { Darwin.close(descriptor) }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if !cancelled { cancelled = true; _ = shutdown(descriptor, SHUT_RDWR) }
    }
    func shutdownWrite() { _ = shutdown(descriptor, SHUT_WR) }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func wait(_ events: Int16, deadline: Date) throws {
        while true {
            if isCancelled { throw CustomsBackendError.message("连接已取消") }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CustomsBackendError.message("网络读写/连接超时") }
            var p = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&p, 1, Int32(min(remaining * 1000, 250).rounded(.up)))
            if result < 0 { if errno == EINTR { continue }; throw CustomsBackendError.system("poll") }
            if result > 0 {
                if p.revents & Int16(POLLNVAL) != 0 { throw CustomsBackendError.message("socket 不可用") }
                return
            }
        }
    }
    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        let deadline = Date().addingTimeInterval(Self.ioTimeout)
        while true {
            lock.lock()
            if cancelled { lock.unlock(); throw CustomsBackendError.message("连接已取消") }
            let result = recv(descriptor, buffer, count, 0)
            let error = errno
            lock.unlock()
            if result >= 0 { return result }
            if error == EINTR { continue }
            if error == EAGAIN || error == EWOULDBLOCK { try wait(Int16(POLLIN), deadline: deadline); continue }
            throw CustomsBackendError.message("socket 读取失败: \(String(cString: strerror(error)))")
        }
    }
    func write(_ buffer: UnsafeRawPointer, count: Int) throws {
        let deadline = Date().addingTimeInterval(Self.ioTimeout)
        var offset = 0
        while offset < count {
            lock.lock()
            if cancelled { lock.unlock(); throw CustomsBackendError.message("连接已取消") }
            let result = send(descriptor, buffer.advanced(by: offset), count - offset, 0)
            let error = errno
            lock.unlock()
            if result > 0 { offset += result; continue }
            if result < 0 && error == EINTR { continue }
            if result < 0 && (error == EAGAIN || error == EWOULDBLOCK) {
                try wait(Int16(POLLOUT), deadline: deadline); continue
            }
            throw CustomsBackendError.message("socket 写入失败: \(String(cString: strerror(error)))")
        }
    }
    /// Nonblocking callbacks used by SecureTransport; no polling while the TLS context lock is held.
    func tlsRead(_ buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if cancelled { errno = ECANCELED; return -1 }
        let result = recv(descriptor, buffer, count, 0)
        let code = errno
        if result < 0 && code != EAGAIN && code != EWOULDBLOCK && code != EINTR && tlsIOFailure == nil {
            tlsIOFailure = ("读取", code)
        }
        errno = code
        return result
    }
    func tlsWrite(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if cancelled { errno = ECANCELED; return -1 }
        let result = send(descriptor, buffer, count, 0)
        let code = errno
        if result < 0 && code != EAGAIN && code != EWOULDBLOCK && code != EINTR && tlsIOFailure == nil {
            tlsIOFailure = ("写入", code)
        }
        errno = code
        return result
    }
    static func listen(port: UInt16, lan: Bool) throws -> CustomsSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CustomsBackendError.system("创建监听 socket") }
        let socket = try CustomsSocket(fd)
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = lan ? INADDR_ANY : inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, Darwin.listen(fd, 64) == 0 else { throw CustomsBackendError.system("监听端口 \(port)") }
        return socket
    }
    func acceptClient() throws -> CustomsSocket? {
        let fd = Darwin.accept(descriptor, nil, nil)
        if fd >= 0 { return try CustomsSocket(fd) }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
        throw CustomsBackendError.system("accept")
    }
    var localPort: UInt16 {
        var address = sockaddr_in(); var length = socklen_t(MemoryLayout.size(ofValue: address))
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
    struct Address: Sendable { let bytes: Data; let family: Int32; let isLocal: Bool }
    private static let resolver = CustomsDNSResolver()
    static func refreshDNSCache() { resolver.clearCache() }
    nonisolated enum ConnectionPhase: Sendable { case dns, connecting }

    static func connect(host: String, port: UInt16, proxyPort: UInt16,
                        isCancelled: @escaping @Sendable () -> Bool = { false },
                        onPhase: @escaping @Sendable (ConnectionPhase) -> Void = { _ in },
                        register: (CustomsSocket) throws -> Void) throws -> CustomsSocket {
        // Same-port destinations are deliberately rejected even if remote: no proxy loops.
        guard port != proxyPort else { throw CustomsBackendError.message("拒绝转发到本代理端口 \(port)，防止循环") }
        onPhase(.dns)
        let addresses = try resolver.resolve(host: host, port: port, isCancelled: isCancelled)
        onPhase(.connecting)
        return try connect(addresses: addresses, host: host, port: port,
                           isCancelled: isCancelled, register: register)
    }

    /// Preserve resolver preference and ordering within each family, alternating v4/v6.
    static func interleavedAddresses(_ addresses: [Address]) -> [Address] {
        guard let first = addresses.first(where: { $0.family == AF_INET || $0.family == AF_INET6 }) else {
            return addresses
        }
        let preferred = addresses.filter { $0.family == first.family }
        let alternate = addresses.filter { $0.family == (first.family == AF_INET ? AF_INET6 : AF_INET) }
        var ordered: [Address] = []
        for index in 0..<max(preferred.count, alternate.count) {
            if index < preferred.count { ordered.append(preferred[index]) }
            if index < alternate.count { ordered.append(alternate[index]) }
        }
        ordered.append(contentsOf: addresses.filter { $0.family != AF_INET && $0.family != AF_INET6 })
        return ordered
    }

    /// One monotonic deadline for the whole race, not one timeout per address.
    /// Older attempts remain alive when a stagger starts the next candidate.
    static func connect(addresses: [Address], host: String, port: UInt16,
                        timeout: TimeInterval = 10, fallbackDelay: TimeInterval = 0.25,
                        isCancelled: @escaping @Sendable () -> Bool = { false },
                        register: (CustomsSocket) throws -> Void) throws -> CustomsSocket {
        let candidates = interleavedAddresses(addresses)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        let stagger = max(0, fallbackDelay)
        var nextLaunch = ProcessInfo.processInfo.systemUptime
        var nextIndex = 0
        var inflight: [CustomsSocket] = []
        var winner: CustomsSocket?
        var lastError: Error = CustomsBackendError.message("连接 \(host):\(port) 没有可用地址")
        defer {
            // Session may retain these objects. Shutdown now; close only at deinit,
            // so cancellation never touches a descriptor reused by another request.
            for socket in inflight where socket !== winner { socket.cancel() }
        }
        func checkCancellation() throws {
            if isCancelled() || inflight.contains(where: { $0.isCancelled }) {
                throw CustomsBackendError.message("连接 \(host):\(port) 已取消")
            }
        }
        func failure(_ error: Int32) -> CustomsBackendError {
            .message("连接 \(host):\(port) 失败: \(String(cString: strerror(error))) (errno=\(error))")
        }
        func checkDeadline() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CustomsBackendError.message("连接 \(host):\(port) 超时 (errno=\(ETIMEDOUT)); \(lastError.localizedDescription)")
            }
        }
        while true {
            try checkCancellation()
            if nextIndex == candidates.count && inflight.isEmpty { throw lastError }
            try checkDeadline()
            let now = ProcessInfo.processInfo.systemUptime
            if nextIndex < candidates.count && (inflight.isEmpty || now >= nextLaunch) {
                let address = candidates[nextIndex]
                nextIndex += 1
                nextLaunch = now + stagger
                let fd = Darwin.socket(address.family, SOCK_STREAM, 0)
                if fd < 0 { lastError = failure(errno); continue }
                let socket: CustomsSocket
                do { socket = try CustomsSocket(fd) }
                catch {
                    lastError = CustomsBackendError.message("连接 \(host):\(port) 失败: \(error.localizedDescription)")
                    continue
                }
                inflight.append(socket)
                // A session registration failure is terminal, never a candidate failure.
                try register(socket)
                try checkCancellation()
                try checkDeadline()
                var storage = sockaddr_storage()
                guard address.bytes.count >= MemoryLayout<sockaddr>.size,
                      address.bytes.count <= MemoryLayout<sockaddr_storage>.size else {
                    socket.cancel(); inflight.removeLast(); lastError = failure(EINVAL); continue
                }
                _ = withUnsafeMutableBytes(of: &storage) { address.bytes.copyBytes(to: $0) }
                socket.lock.lock()
                if socket.cancelled {
                    socket.lock.unlock()
                    throw CustomsBackendError.message("连接 \(host):\(port) 已取消")
                }
                let result = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(address.bytes.count))
                    }
                }
                let error = errno
                socket.lock.unlock()
                if result == 0 {
                    try checkCancellation(); try checkDeadline()
                    winner = socket; return socket
                }
                if error != EINPROGRESS && error != EINTR && error != EALREADY {
                    lastError = failure(error)
                    socket.cancel(); inflight.removeLast()
                    continue
                }
            }

            // Poll every inflight descriptor together. Bound each wait for cancellation,
            // the next stagger, and the global deadline (without shortening dial timeout).
            let current = ProcessInfo.processInfo.systemUptime
            var wait = min(0.05, max(0, deadline - current))
            if nextIndex < candidates.count { wait = min(wait, max(0, nextLaunch - current)) }
            var descriptors = inflight.map { pollfd(fd: $0.descriptor, events: Int16(POLLOUT), revents: 0) }
            let result = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), Int32((wait * 1000).rounded(.up)))
            }
            let pollError = errno
            try checkCancellation()
            try checkDeadline()
            if result < 0 {
                if pollError == EINTR { continue }
                throw failure(pollError)
            }
            if result == 0 { continue }
            // Reverse removal keeps descriptors and inflight indexes aligned.
            for index in descriptors.indices.reversed() where descriptors[index].revents != 0 {
                let socket = inflight[index]
                var error: Int32 = 0
                socket.lock.lock()
                if socket.cancelled {
                    socket.lock.unlock()
                    throw CustomsBackendError.message("连接 \(host):\(port) 已取消")
                }
                if descriptors[index].revents & Int16(POLLNVAL) != 0 {
                    error = EBADF
                } else {
                    var size = socklen_t(MemoryLayout.size(ofValue: error))
                    if getsockopt(socket.descriptor, SOL_SOCKET, SO_ERROR, &error, &size) != 0 {
                        error = errno
                    } else if error == 0 {
                        // Readiness alone (e.g. HUP) is not evidence of a connected peer.
                        var peer = sockaddr_storage()
                        var length = socklen_t(MemoryLayout.size(ofValue: peer))
                        let connected = withUnsafeMutablePointer(to: &peer) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                getpeername(socket.descriptor, $0, &length)
                            }
                        }
                        if connected != 0 { error = errno }
                    }
                }
                socket.lock.unlock()
                if error == 0 {
                    try checkCancellation(); try checkDeadline()
                    winner = socket; return socket
                }
                lastError = failure(error)
                socket.cancel(); inflight.remove(at: index)
                // A concrete failure permits an immediate next attempt.
                nextLaunch = ProcessInfo.processInfo.systemUptime
            }
        }
    }
}

/// getaddrinfo is not cancellable. Limit actual resolver workers, not HTTP callers:
/// duplicate destinations share one job, and additional jobs queue without occupying workers.
nonisolated final class CustomsDNSResolver: @unchecked Sendable {
    typealias Lookup = @Sendable (String, UInt16) throws -> [CustomsSocket.Address]
    private struct Key: Hashable { let host: String; let port: UInt16 }
    private typealias Outcome = Result<[CustomsSocket.Address], CustomsBackendError>
    private final class Job: @unchecked Sendable {
        let key: Key; let generation: UUID
        var waiters = 0; var running = false; var outcome: Outcome?
        init(key: Key, generation: UUID) { self.key = key; self.generation = generation }
    }
    private struct CacheEntry { let outcome: Outcome; let expiresAt: Date }
    private let condition = NSCondition()
    private let lookup: Lookup
    private let maximumConcurrent: Int
    private let maximumPending: Int
    private let cacheLimit: Int
    private let cacheTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private var generation = UUID()
    private var active = 0
    private var jobs: [Key: Job] = [:]
    private var pending: [Job] = []
    private var cache: [Key: CacheEntry] = [:]

    init(maximumConcurrent: Int = 16, maximumPending: Int = 128, cacheLimit: Int = 256,
         cacheTTL: TimeInterval = 30, negativeTTL: TimeInterval = 2,
         lookup: @escaping Lookup = CustomsDNSResolver.systemLookup) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumPending = max(1, maximumPending)
        self.cacheLimit = max(1, cacheLimit)
        self.cacheTTL = max(0, cacheTTL); self.negativeTTL = max(0, negativeTTL)
        self.lookup = lookup
    }

    func clearCache() {
        condition.lock(); defer { condition.unlock() }
        generation = UUID(); cache.removeAll()
    }

    func resolve(host: String, port: UInt16, timeout: TimeInterval = 10,
                 isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [CustomsSocket.Address] {
        if isCancelled() { throw CustomsBackendError.message("DNS 解析已取消") }
        // Numeric addresses never consume a DNS slot, including all loopback test clients.
        if let address = Self.numericAddress(host, port: port) { return [address] }
        let key = Key(host: host.lowercased(), port: port)
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        var joined: Job?
        defer {
            if let job = joined {
                job.waiters -= 1
                // Unneeded queued jobs must not keep running after callers stop/time out.
                if job.waiters == 0 && !job.running && job.outcome == nil {
                    pending.removeAll { $0 === job }
                    jobs.removeValue(forKey: key)
                    condition.broadcast()
                }
            }
            condition.unlock()
        }
        while true {
            if isCancelled() { throw CustomsBackendError.message("DNS 解析 \(host) 已取消") }
            guard deadline.timeIntervalSinceNow > 0 else {
                throw CustomsBackendError.message("DNS 解析 \(host) 超时（含排队时间）；请检查 Mac 网络、VPN 和 DNS 配置")
            }
            if let job = joined {
                if let outcome = job.outcome { return try outcome.get() }
            } else {
                if let entry = cache[key] {
                    if entry.expiresAt > Date() { return try entry.outcome.get() }
                    cache.removeValue(forKey: key)
                }
                if let job = jobs[key] {
                    job.waiters += 1; joined = job
                } else if pending.count < maximumPending {
                    let job = Job(key: key, generation: generation)
                    job.waiters = 1; joined = job; jobs[key] = job; pending.append(job)
                    scheduleLocked()
                }
            }
            if joined?.outcome != nil { continue }
            // Poll cancellation even when a system resolver remains blocked.
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    private func scheduleLocked() {
        while active < maximumConcurrent && !pending.isEmpty {
            let job = pending.removeFirst()
            job.running = true; active += 1
            DispatchQueue.global(qos: .userInitiated).async { [self, job] in
                let outcome: Outcome
                do {
                    let addresses = try lookup(job.key.host, job.key.port)
                    guard !addresses.isEmpty else { throw CustomsBackendError.message("DNS 解析 \(job.key.host) 未返回可用地址") }
                    outcome = .success(addresses)
                } catch {
                    outcome = .failure(.message(error.localizedDescription))
                }
                condition.lock()
                job.outcome = outcome; active -= 1
                jobs.removeValue(forKey: job.key)
                if job.generation == generation {
                    let now = Date()
                    cache = cache.filter { $0.value.expiresAt > now }
                    if cache.count >= cacheLimit, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                        cache.removeValue(forKey: oldest)
                    }
                    let ttl: TimeInterval
                    switch outcome { case .success: ttl = cacheTTL; case .failure: ttl = negativeTTL }
                    if ttl > 0 { cache[job.key] = CacheEntry(outcome: outcome, expiresAt: now.addingTimeInterval(ttl)) }
                }
                scheduleLocked(); condition.broadcast(); condition.unlock()
            }
        }
    }

    private static func numericAddress(_ host: String, port: UInt16) -> CustomsSocket.Address? {
        var ipv4 = sockaddr_in()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4.sin_addr) }) == 1 {
            ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); ipv4.sin_family = sa_family_t(AF_INET)
            ipv4.sin_port = port.bigEndian
            let ip = UInt32(bigEndian: ipv4.sin_addr.s_addr)
            return CustomsSocket.Address(bytes: withUnsafeBytes(of: &ipv4) { Data($0) }, family: AF_INET, isLocal: ip >> 24 == 127 || ip == 0)
        }
        var ipv6 = sockaddr_in6()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6.sin6_addr) }) == 1 {
            ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); ipv6.sin6_family = sa_family_t(AF_INET6)
            ipv6.sin6_port = port.bigEndian
            let local = withUnsafeBytes(of: &ipv6.sin6_addr) { $0.dropLast().allSatisfy { $0 == 0 } && ($0.last == 0 || $0.last == 1) }
            return CustomsSocket.Address(bytes: withUnsafeBytes(of: &ipv6) { Data($0) }, family: AF_INET6, isLocal: local)
        }
        return nil
    }

    private static func systemLookup(host: String, port: UInt16) throws -> [CustomsSocket.Address] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, String(port), &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        guard result == 0 else {
            throw CustomsBackendError.message("DNS 解析 \(host) 失败: \(String(cString: gai_strerror(result)))。请检查 Mac 网络、VPN 和 DNS 配置")
        }
        var addresses: [CustomsSocket.Address] = []
        var entry = list
        while let current = entry {
            let info = current.pointee
            if let pointer = info.ai_addr {
                addresses.append(CustomsSocket.Address(bytes: Data(bytes: pointer, count: Int(info.ai_addrlen)), family: info.ai_family, isLocal: false))
            }
            entry = info.ai_next
        }
        return addresses
    }
}

nonisolated protocol CustomsTransport: AnyObject, Sendable {
    func read(maximum: Int) throws -> Data
    func write(_ data: Data) throws
}

nonisolated final class CustomsPlainTransport: CustomsTransport, @unchecked Sendable {
    let socket: CustomsSocket
    init(_ socket: CustomsSocket) { self.socket = socket }
    func read(maximum: Int = 32_768) throws -> Data {
        var data = Data(count: maximum)
        let count = try data.withUnsafeMutableBytes { try socket.read(into: $0.baseAddress!, count: maximum) }
        data.count = count; return data
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { if let base = $0.baseAddress { try socket.write(base, count: $0.count) } }
    }
}
