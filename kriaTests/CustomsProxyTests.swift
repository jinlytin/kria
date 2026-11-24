import Foundation
import Darwin
@preconcurrency import Security
import XCTest
#if !CUSTOMS_STANDALONE_TEST
@testable import kria
#endif

nonisolated final class CustomsProxyTests: XCTestCase {
    private final class MemoryTransport: CustomsTransport, @unchecked Sendable {
        var input: Data; var output = Data(); let fragment: Int
        init(_ text: String, fragment: Int = 7) { input = Data(text.utf8); self.fragment = fragment }
        func read(maximum: Int) throws -> Data {
            let data = Data(input.prefix(min(maximum, fragment))); input.removeFirst(data.count); return data
        }
        func write(_ data: Data) throws { output.append(data) }
    }
    private final class Events: @unchecked Sendable {
        let lock = NSLock(); var values: [CustomsTransaction] = []; var failures: [String] = []
        let started = DispatchSemaphore(value: 0); let finished = DispatchSemaphore(value: 0)
        let changed = DispatchSemaphore(value: 0); let stopped = DispatchSemaphore(value: 0)
        func waitForTransaction(where predicate: (CustomsTransaction) -> Bool) -> CustomsTransaction? {
            let deadline = DispatchTime.now() + 5
            while true {
                if let match = transactions.first(where: predicate) { return match }
                if changed.wait(timeout: deadline) != .success { return transactions.first(where: predicate) }
            }
        }
        func receive(_ event: CustomsProxyEvent) {
            switch event {
            case .started: started.signal()
            case .stopped: stopped.signal()
            case .transaction(let transaction):
                lock.lock(); values.append(transaction); lock.unlock()
                changed.signal()
                if transaction.finishedAt != nil { finished.signal() }
            case .failed(let message): lock.lock(); failures.append(message); lock.unlock()
            }
        }
        var last: CustomsTransaction? { lock.lock(); defer { lock.unlock() }; return values.last }
        var transactions: [CustomsTransaction] { lock.lock(); defer { lock.unlock() }; return values }
        var serverFailures: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    }
    func testChunkedAndInterimPreserveWire() throws {
        let input = MemoryTransport("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n3;foo=bar\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: yes\r\n\r\nNEXT")
        let reader = CustomsHTTPReader(input)
        XCTAssertEqual(try reader.head().status, 100)
        let head = try reader.head()
        XCTAssertEqual(head.values("set-cookie"), ["a=1", "b=2"])
        let output = MemoryTransport(""); var captured = Data()
        try reader.forward(CustomsHTTP.framing(head, responseTo: "GET"), to: output) { captured.append($0) }
        XCTAssertEqual(captured, Data("abcde".utf8))
        XCTAssertEqual(output.output, Data("3;foo=bar\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: yes\r\n\r\n".utf8))
        XCTAssertEqual(try reader.exact(4), Data("NEXT".utf8))
    }
    func testFramingRejectsAmbiguityAndTruncation() throws {
        for wire in [
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n"
        ] {
            let reader = CustomsHTTPReader(MemoryTransport(wire))
            let head = try reader.head()
            XCTAssertThrowsError(try CustomsHTTP.framing(head, responseTo: "GET"))
        }
        let reader = CustomsHTTPReader(MemoryTransport("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc"))
        let head = try reader.head()
        XCTAssertThrowsError(try reader.forward(CustomsHTTP.framing(head, responseTo: "GET"), to: MemoryTransport("")) { _ in })
        let closed = CustomsHTTPReader(MemoryTransport("HTTP/1.0 200 OK\r\n\r\nclosed"))
        let closedHead = try closed.head(); let output = MemoryTransport("")
        try closed.forward(CustomsHTTP.framing(closedHead, responseTo: "GET"), to: output) { _ in }
        XCTAssertEqual(output.output, Data("closed".utf8))
    }
    func testRulesAndRawURL() throws {
        let reader = CustomsHTTPReader(MemoryTransport("POST http://example.test/a%2Fb?q=%FF+%20 HTTP/1.1\r\nHost: example.test\r\nCookie: a=1\r\nCookie: b=2\r\nx-test: old\r\nX-Test: duplicate\r\nConnection: X-Private\r\n\r\n"))
        var head = try reader.head()
        XCTAssertEqual(try CustomsHTTP.destination(head).target, "/a%2Fb?q=%FF+%20")
        let rules = [
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Test", value: "new"),
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "Host", value: "bad"),
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Private", value: "bad"),
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Empty", value: " \t"),
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Bad", value: "hello\r\nInjected: x")
        ]
        XCTAssertEqual(head.rewrite(rules: rules, enabled: true), ["X-Test"])
        XCTAssertEqual(head.values("x-test"), ["new"])
        XCTAssertEqual(head.values("cookie"), ["a=1", "b=2"])
        XCTAssertEqual(head.values("host"), ["example.test"])
        XCTAssertTrue(CustomsHTTP.matches("a.example.test", patterns: ["*.example.test"]))
        XCTAssertFalse(CustomsHTTP.matches("evil-example.test", patterns: ["*.example.test"]))
        XCTAssertFalse(CustomsHTTP.matches("example.test", patterns: []))
    }
    private static func accepted(_ listener: CustomsSocket) throws -> CustomsSocket {
        try listener.wait(Int16(POLLIN), deadline: Date().addingTimeInterval(5))
        guard let socket = try listener.acceptClient() else { throw CustomsBackendError.message("测试 accept 失败") }
        return socket
    }
    private static func reservedPort() throws -> UInt16 { let listener = try CustomsSocket.listen(port: 0, lan: false); return listener.localPort }
    func testLoopbackProxyRawUploadInterimAndCaptureLimit() throws {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let originDone = DispatchSemaphore(value: 0)
        let body = Data([0, 255, 13, 10, 128]) + Data(repeating: 65, count: 600_000)
        DispatchQueue.global().async {
            defer { originDone.signal() }
            do {
                let socket = try Self.accepted(origin); defer { socket.cancel() }
                let transport = CustomsPlainTransport(socket); let reader = CustomsHTTPReader(transport)
                let head = try reader.head()
                XCTAssertEqual(head.firstLine, "POST /raw%2Fpath?q=%FF HTTP/1.1")
                XCTAssertEqual(head.values("cookie"), ["a=1", "b=2"])
                XCTAssertEqual(head.values("x-rewrite"), ["changed"])
                XCTAssertTrue(head.values("expect").isEmpty)
                try transport.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                let sink = MemoryTransport("")
                try reader.forward(CustomsHTTP.framing(head), to: sink) { _ in }
                XCTAssertEqual(sink.output, body)
                try transport.write(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n".utf8))
                try transport.write(Data(String(body.count, radix: 16).utf8) + Data("\r\n".utf8) + body + Data("\r\n0\r\n\r\n".utf8))
            } catch { XCTFail("本地源站: \(error)") }
        }
        let events = Events(); let proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: CustomsProxyConfiguration(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: true,
            headerRules: [CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Rewrite", value: "changed")]))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }; defer { socket.cancel() }
        let client = CustomsPlainTransport(socket); let reader = CustomsHTTPReader(client)
        try client.write(Data("POST http://127.0.0.1:\(originPort)/raw%2Fpath?q=%FF HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nCookie: a=1\r\nCookie: b=2\r\nX-Rewrite: old\r\nContent-Length: \(body.count)\r\nExpect: 100-continue\r\n\r\n".utf8))
        XCTAssertEqual(try reader.head().status, 100)
        try client.write(body)
        let head = try reader.head(); XCTAssertEqual(head.status, 200)
        let output = MemoryTransport(""); var captured = Data()
        try reader.forward(CustomsHTTP.framing(head, responseTo: "POST"), to: output) { captured.append($0) }
        XCTAssertEqual(captured, body)
        XCTAssertEqual(originDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
        let final = try XCTUnwrap(events.last)
        XCTAssertNil(final.error)
        XCTAssertEqual(final.requestBody.count, CustomsHTTP.captureLimit)
        XCTAssertEqual(final.responseBody.count, CustomsHTTP.captureLimit)
        XCTAssertTrue(final.requestBodyTruncated); XCTAssertTrue(final.responseBodyTruncated)
        XCTAssertEqual(final.responseByteCount, body.count)
        XCTAssertEqual(final.rewrittenHeaders, ["X-Rewrite"])
    }
    func testExpectWithoutOriginContinueAndConnectionClose() throws {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let proxyPort = try Self.reservedPort(), originPort = origin.localPort
        let done = DispatchSemaphore(value: 0)
        let body = Data("upload without origin 100".utf8)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin); defer { socket.cancel() }
                let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(CustomsPlainTransport(socket))
                let head = try reader.head()
                XCTAssertTrue(head.values("expect").isEmpty)
                let sink = MemoryTransport("")
                try reader.forward(CustomsHTTP.framing(head), to: sink) { _ in }
                XCTAssertEqual(sink.output, body)
                try transport.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\ncOnNeCtIoN: keep-alive\r\nConnection: keep-alive\r\nProxy-Connection: keep-alive\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nok".utf8))
            } catch { XCTFail("无 100 源站: \(error)") }
        }
        let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }; defer { socket.cancel() }
        let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(CustomsPlainTransport(socket))
        let start = Date()
        try client.write(Data("POST http://127.0.0.1:\(originPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nContent-Length: \(body.count)\r\nExpect: 100-continue\r\n\r\n".utf8))
        XCTAssertEqual(try reader.head().status, 100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        try client.write(body)
        let response = try reader.head()
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.values("connection"), ["close"])
        XCTAssertTrue(response.values("proxy-connection").isEmpty)
        XCTAssertEqual(response.values("set-cookie"), ["a=1", "b=2"])
        XCTAssertEqual(try reader.exact(2), Data("ok".utf8))
        XCTAssertTrue(try reader.block(maximum: 1).isEmpty)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
        let final = try XCTUnwrap(events.last)
        XCTAssertFalse(final.requestBodyIncomplete)
        XCTAssertTrue(final.canCopyCurl)
        XCTAssertEqual(final.responseHeaders.map { $0.name + ": " + $0.value }, response.headers.map { $0.name + ": " + $0.value })
    }
    func testEarlyFinalMarksIncompleteUploadWithoutError() throws {
        for expect in [false, true] {
            let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
            let proxyPort = try Self.reservedPort(), originPort = origin.localPort
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    let socket = try Self.accepted(origin)
                    let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                    let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(CustomsPlainTransport(socket))
                    let head = try reader.head()
                    XCTAssertTrue(head.values("expect").isEmpty)
                    try transport.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
                    _ = try? reader.block(maximum: 1)
                } catch { XCTFail("早响应源站: \(error)") }
            }
            let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
            try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
            XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
            let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
            let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
            let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(CustomsPlainTransport(socket))
            try transport.write(Data("POST http://127.0.0.1:\(originPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nContent-Length: 1000000\r\n\(expect ? "Expect: 100-continue\r\n" : "")\r\n".utf8))
            if expect { XCTAssertEqual(try reader.head().status, 100) }
            XCTAssertEqual(try reader.head().status, 200)
            XCTAssertEqual(try reader.exact(2), Data("ok".utf8))
            XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            let final = try XCTUnwrap(events.last)
            XCTAssertNil(final.error)
            XCTAssertTrue(final.requestBodyIncomplete); XCTAssertFalse(final.requestBodyComplete)
            XCTAssertEqual(final.phase, .completed)
            try assertClosedTimings(final, phases: [.dns, .connecting, .sendingRequest, .receivingResponse])
            proxy.stop(); XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
            assertOrderedSnapshots(events, final: final)
            XCTAssertFalse(final.canCopyCurl); XCTAssertNil(final.curl())
        }
    }
    func testFailedUploadMarksIncomplete() throws {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let proxyPort = try Self.reservedPort(), originPort = origin.localPort
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin); defer { socket.cancel() }
                let reader = CustomsHTTPReader(CustomsPlainTransport(socket))
                _ = try reader.head(); _ = try? reader.block(maximum: 1)
            } catch { XCTFail("失败上传源站: \(error)") }
        }
        let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }; defer { socket.cancel() }
        try CustomsPlainTransport(socket).write(Data("POST http://127.0.0.1:\(originPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nContent-Length: 100\r\n\r\n".utf8))
        socket.shutdownWrite()
        XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let final = try XCTUnwrap(events.last)
        XCTAssertNotNil(final.error); XCTAssertTrue(final.requestBodyIncomplete)
        XCTAssertFalse(final.canCopyCurl)
    }
    func testConnectTunnelAndStop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsTunnelPolicy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        for decrypt in [false, true] {
            let expectedPolicy: CustomsHTTPSHandling = decrypt ? .hostExcluded : .disabled
            let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
            let proxyPort = try Self.reservedPort(); let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    let socket = try Self.accepted(origin)
                    let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                    let transport = CustomsPlainTransport(socket); let reader = CustomsHTTPReader(transport)
                    let data = try reader.exact(5); try transport.write(data)
                } catch { XCTFail("隧道源站: \(error)") }
            }
            let events = Events()
            let proxy = CustomsProxyServer(certificateAuthority: ca) { events.receive($0) }; defer { proxy.stop() }
            try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: decrypt,
                                                sslHosts: ["*.excluded.test"], rewriteEnabled: false, headerRules: []))
            XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
            let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
            let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
            let client = CustomsPlainTransport(socket); let reader = CustomsHTTPReader(client)
            try client.write(Data("CONNECT 127.0.0.1:\(origin.localPort) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.localPort)\r\n\r\nhello".utf8))
            XCTAssertEqual(try reader.head().status, 200)
            XCTAssertEqual(try reader.exact(5), Data("hello".utf8))
            socket.shutdownWrite()
            XCTAssertTrue(try reader.block(maximum: 1).isEmpty)
            XCTAssertFalse(socket.isCancelled, "不能把超时取消当成正常隧道 EOF")
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            let final = try finalTransaction(events, method: "CONNECT")
            XCTAssertTrue(final.isTunnel); XCTAssertNil(final.error)
            XCTAssertEqual(final.httpsHandling, expectedPolicy)
            XCTAssertNil(final.relatedTransactionID)
            XCTAssertEqual(final.statusCode, 200); XCTAssertFalse(final.responseIsLocal)
            XCTAssertTrue(final.responseBody.isEmpty)
            let snapshots = events.transactions.filter { $0.id == final.id }
            XCTAssertEqual(snapshots.first?.phase, .captured)
            XCTAssertTrue(snapshots.allSatisfy { $0.httpsHandling == expectedPolicy })
            XCTAssertFalse(snapshots.contains { [.certificate, .upstreamTLS, .clientTLS, .clientRequest].contains($0.phase) })
            try assertClosedTimings(final, phases: [.dns, .connecting, .tunnel])
            proxy.stop(); XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
            assertOrderedSnapshots(events, final: final)
            XCTAssertThrowsError(try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: proxyPort) { _ in })
        }
    }
    /// The accepted socket has one owner: no transport or timeout closure retains it.
    /// Releasing it with abortive linger closes at deinit, rather than shutdown via cancel().
    private static func resetOriginAfterPayload(_ listener: CustomsSocket, tlsClientHello: Bool) throws {
        var socket: CustomsSocket? = try accepted(listener)
        let deadline = Date().addingTimeInterval(5)
        var received = Data()
        var required = 5
        while received.count < required {
            try socket!.wait(Int16(POLLIN), deadline: deadline)
            var buffer = [UInt8](repeating: 0, count: required - received.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(socket!.descriptor, $0.baseAddress!, $0.count, 0)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CustomsBackendError.system("RST fixture 读取")
            }
            guard count > 0 else { throw CustomsBackendError.message("RST fixture 在载荷前收到 EOF") }
            received.append(contentsOf: buffer.prefix(count))
            if tlsClientHello && received.count >= 5 && required == 5 {
                XCTAssertEqual(received[0], 22, "上游必须先收到真实 TLS handshake record")
                let length = Int(received[3]) * 256 + Int(received[4])
                guard length > 0, length <= 18_432 else {
                    throw CustomsBackendError.message("RST fixture 非法 TLS record 长度")
                }
                required = 5 + length
            }
        }
        if tlsClientHello {
            XCTAssertEqual(received[5], 1, "读取完整 ClientHello record 后才复位")
        } else {
            XCTAssertEqual(received, Data("hello".utf8))
        }
        var abortive = linger(l_onoff: 1, l_linger: 0)
        guard setsockopt(socket!.descriptor, SOL_SOCKET, SO_LINGER, &abortive,
                         socklen_t(MemoryLayout.size(ofValue: abortive))) == 0 else {
            throw CustomsBackendError.system("RST fixture SO_LINGER")
        }
        // Never Darwin.close a descriptor still owned by CustomsSocket; nil is the close.
        socket = nil
    }

    func testDisabledCONNECTUpstreamResetReportsReadEndpointWithout502After200() throws {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try Self.resetOriginAfterPayload(origin, tlsClientHello: false) }
            catch { XCTFail("明文 RST 源站: \(error)") }
        }
        let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false,
                                            sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
        try client.write(Data("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        XCTAssertEqual(try reader.head().status, 200)
        _ = try XCTUnwrap(events.waitForTransaction { $0.method == "CONNECT" && $0.phase == .tunnel })
        try client.write(Data("hello".utf8))
        var after200 = Data()
        try reader.forward(.close, to: MemoryTransport("")) { after200.append($0) }
        XCTAssertTrue(after200.isEmpty, "200 之后不能追加伪造的 502 或错误正文")
        XCTAssertFalse(socket.isCancelled, "不能用五秒 deadline 取消冒充 RST 导致的 EOF")
        // Capture the first result before any test cancellation can obscure the read endpoint.
        let final = try finalTransaction(events, method: "CONNECT")
        timeout.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let error = try XCTUnwrap(final.error)
        XCTAssertTrue(error.contains("CONNECT 127.0.0.1"))
        XCTAssertTrue(error.contains(CustomsRequestPhase.tunnel.title))
        XCTAssertTrue(error.contains("读取上游"))
        XCTAssertTrue(error.localizedCaseInsensitiveContains("Connection reset"))
        XCTAssertEqual(final.phase, .tunnel); XCTAssertEqual(final.httpsHandling, .disabled)
        XCTAssertEqual(final.statusCode, 200); XCTAssertFalse(final.responseIsLocal)
        XCTAssertNil(final.relatedTransactionID)
        XCTAssertTrue(final.responseBody.isEmpty); XCTAssertEqual(final.responseByteCount, 0)
        XCTAssertFalse(final.canCopyCurl)
        XCTAssertTrue(events.transactions.allSatisfy { $0.method == "CONNECT" && $0.httpsHandling == .disabled })
        try assertClosedTimings(final, phases: [.dns, .connecting, .tunnel])
        proxy.stop(); XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
        assertOrderedSnapshots(events, final: final)
    }

    func testMITMUpstreamTLSResetBefore200Returns502WithoutHTTPRecordOrTunnelFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsUpstreamTLSReset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try Self.resetOriginAfterPayload(origin, tlsClientHello: true) }
            catch { XCTFail("TLS RST 源站: \(error)") }
        }
        let events = Events()
        let proxy = CustomsProxyServer(certificateAuthority: ca) { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: true,
                                            sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
        try client.write(Data("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        let response = try reader.head()
        XCTAssertEqual(response.status, 502, "上游握手未成功，不能先发送 CONNECT 200")
        var body = Data()
        try reader.forward(CustomsHTTP.framing(response, responseTo: "CONNECT"), to: MemoryTransport("")) { body.append($0) }
        XCTAssertTrue(try reader.block(maximum: 1).isEmpty)
        XCTAssertFalse(socket.isCancelled, "真实 RST 应在五秒 deadline 前返回")
        let final = try finalTransaction(events, method: "CONNECT")
        timeout.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        try assertLocalResponse(response, body: body, final: final)
        XCTAssertEqual(final.phase, .upstreamTLS); XCTAssertEqual(final.httpsHandling, .decrypting)
        XCTAssertNil(final.relatedTransactionID)
        let error = try XCTUnwrap(final.error)
        XCTAssertTrue(error.contains("CONNECT 127.0.0.1"))
        XCTAssertTrue(error.contains(CustomsRequestPhase.upstreamTLS.title))
        XCTAssertTrue(error.contains("上游 TLS"))
        XCTAssertTrue(error.localizedCaseInsensitiveContains("socket"), "保留底层 socket 诊断，而非仅泛化为证书错误")
        XCTAssertTrue(error.contains("errno="), "必须保留系统错误；不限定具体 errno 或 TLS OSStatus")
        XCTAssertTrue(final.connectNotice.contains("与 iPhone 是否信任代理 CA 无关"))
        let snapshots = events.transactions
        XCTAssertTrue(snapshots.allSatisfy { $0.method == "CONNECT" && $0.httpsHandling == .decrypting })
        XCTAssertEqual(Set(snapshots.map(\.id)).count, 1)
        XCTAssertFalse(snapshots.contains { $0.statusCode == 200 })
        XCTAssertFalse(snapshots.contains { [.tunnel, .clientTLS, .clientRequest].contains($0.phase) })
        try assertClosedTimings(final, phases: [.dns, .connecting, .certificate, .upstreamTLS])
        proxy.stop(); XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
        assertOrderedSnapshots(events, final: final)
    }

    private func rootCertificate(_ ca: CustomsCertificateAuthority) throws -> SecCertificate {
        let pem = try String(contentsOf: ca.certificateURL, encoding: .utf8)
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }
    func testCompleteCONNECTMITMHeadersEventsAndRecordingPause() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsE2E-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxyCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("proxy"))
        let originCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("origin"))
        try proxyCA.prepare(); try originCA.prepare()
        let proxyRoot = try rootCertificate(proxyCA), originRoot = try rootCertificate(originCA)
        let identity = try originCA.identity(for: "127.0.0.1")
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let rules = [
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "swimlane", value: ""),
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Replace", value: "new"),
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Added", value: "added"),
            CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Second", value: "second"),
            CustomsHeaderRule(id: UUID(), isEnabled: false, name: "X-Disabled", value: "wrong")
        ]
        let events = Events()
        let proxy = CustomsProxyServer(certificateAuthority: proxyCA, upstreamTrustAnchors: [originRoot]) { events.receive($0) }
        defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: true, sslHosts: ["*"], rewriteEnabled: true, headerRules: rules))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let payload = Data("{\"text\":\"中文 raw body\"}".utf8)
        // 0: rewrite + pause in flight; 1: global rewrite disabled; 2: new request while paused.
        for index in 0..<3 {
            if index == 1 { proxy.setRecording(true); proxy.updateRules(rules, enabled: false) }
            if index == 2 { proxy.setRecording(false) }
            let priorPostIDs = Set(events.transactions.filter { $0.method == "POST" }.map(\.id))
            let headersReceived = DispatchSemaphore(value: 0)
            let releaseResponse = DispatchSemaphore(value: 0)
            defer { releaseResponse.signal() }
            let originDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { originDone.signal() }
                do {
                    let socket = try Self.accepted(origin)
                    let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                    let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", identity: identity)
                    try tls.handshake()
                    let reader = CustomsHTTPReader(tls); let head = try reader.head()
                    XCTAssertEqual(head.firstLine, "POST /mitm%2Fraw?q=%FF HTTP/1.1")
                    XCTAssertEqual(head.values("swimlane"), [])
                    XCTAssertEqual(head.values("cookie"), ["a=1", "b=2"])
                    XCTAssertEqual(head.values("x-disabled"), ["keep"])
                    XCTAssertEqual(head.values("x-replace"), index == 0 ? ["new"] : ["old", "duplicate"])
                    XCTAssertEqual(head.values("x-added"), index == 0 ? ["added"] : [])
                    XCTAssertEqual(head.values("x-second"), index == 0 ? ["second"] : [])
                    headersReceived.signal()
                    let sink = MemoryTransport("")
                    try reader.forward(CustomsHTTP.framing(head), to: sink) { _ in }
                    XCTAssertEqual(sink.output, payload)
                    XCTAssertEqual(releaseResponse.wait(timeout: .now() + 5), .success)
                    try tls.write(Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nContent-Type: application/json\r\n\r\n".utf8) + payload)
                    tls.closeGracefully()
                } catch { XCTFail("MITM origin: \(error)"); headersReceived.signal() }
            }
            let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
            let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
            let plain = CustomsPlainTransport(socket)
            try plain.write(Data("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
            XCTAssertEqual(try CustomsHTTPReader(plain).head().status, 200)
            let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", trustAnchors: [proxyRoot])
            try tls.handshake()
            try tls.write(Data("POST /mitm%2Fraw?q=%FF HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nCookie: a=1\r\nCookie: b=2\r\nX-Replace: old\r\nx-replace: duplicate\r\nX-Disabled: keep\r\nContent-Length: \(payload.count)\r\n\r\n".utf8))
            XCTAssertEqual(headersReceived.wait(timeout: .now() + 5), .success)
            if index == 0 { proxy.setRecording(false) }
            try tls.write(payload)
            if index < 2 {
                let uploaded = try XCTUnwrap(events.waitForTransaction {
                    $0.method == "POST" && !priorPostIDs.contains($0.id) && $0.requestBodyComplete
                })
                XCTAssertEqual(uploaded.phase, .waitingResponse)
                XCTAssertNil(uploaded.statusCode); XCTAssertNil(uploaded.finishedAt)
            }
            releaseResponse.signal()
            let reader = CustomsHTTPReader(tls); let head = try reader.head()
            XCTAssertEqual(head.status, 200)
            var received = Data()
            try reader.forward(CustomsHTTP.framing(head, responseTo: "POST"), to: MemoryTransport("")) { received.append($0) }
            XCTAssertEqual(received, payload)
            XCTAssertEqual(originDone.wait(timeout: .now() + 5), .success)
            if index < 2 {
                // Wait for HTTPS final, not the separate CONNECT final event.
                _ = try XCTUnwrap(events.waitForTransaction {
                    $0.method == "POST" && !priorPostIDs.contains($0.id) && $0.finishedAt != nil
                })
            }
        }
        // Drain ordered event delivery with a final malformed request after re-enabling recording.
        proxy.setRecording(true)
        let malformed = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let malformedTimeout = Self.readDeadline(malformed); defer { malformedTimeout.cancel(); malformed.cancel() }
        let transport = CustomsPlainTransport(malformed)
        try transport.write(Data("INVALID\r\n\r\n".utf8))
        _ = try CustomsHTTPReader(transport).head()
        _ = try XCTUnwrap(events.waitForTransaction { $0.method == "INVALID" && $0.finishedAt != nil })
        proxy.stop()
        XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
        let posts = events.transactions.filter { $0.method == "POST" }
        let finals = posts.filter { $0.finishedAt != nil }
        XCTAssertEqual(finals.count, 2)
        XCTAssertEqual(Set(posts.map(\.id)).count, 2, "暂停后的第三个请求不录制")
        for transaction in finals {
            XCTAssertFalse(transaction.isTunnel); XCTAssertNil(transaction.error)
            XCTAssertEqual(transaction.url, "https://127.0.0.1:\(originPort)/mitm%2Fraw?q=%FF")
            XCTAssertEqual(transaction.requestBody, payload); XCTAssertEqual(transaction.responseBody, payload)
            XCTAssertEqual(transaction.statusCode, 200)
            XCTAssertTrue(transaction.requestBodyComplete); XCTAssertEqual(transaction.phase, .completed)
            try assertClosedTimings(transaction, phases: [.sendingRequest, .waitingResponse, .receivingResponse])
            assertOrderedSnapshots(events, final: transaction)
            let updates = posts.filter { $0.id == transaction.id }
            XCTAssertTrue(updates.contains { $0.finishedAt == nil && $0.statusCode == nil })
            XCTAssertTrue(updates.contains { $0.finishedAt == nil && $0.statusCode == 200 })
        }
        let connects = events.transactions.filter { $0.method == "CONNECT" }
        XCTAssertEqual(Set(connects.map(\.id)).count, 2)
        XCTAssertEqual(connects.filter { $0.finishedAt != nil }.count, 2)
        for connect in connects.filter({ $0.finishedAt != nil }) {
            XCTAssertEqual(connect.phase, .completed)
            try assertClosedTimings(connect, phases: [.dns, .connecting, .certificate, .upstreamTLS, .clientTLS, .clientRequest])
            XCTAssertFalse(Set(finals.map(\.id)).contains(connect.id))
            let relatedID = try XCTUnwrap(connect.relatedTransactionID)
            let firstHTTP = try XCTUnwrap(posts.first { $0.id == relatedID })
            XCTAssertEqual(firstHTTP.relatedTransactionID, connect.id)
            XCTAssertEqual(connect.httpsHandling, .decrypting)
            XCTAssertEqual(firstHTTP.httpsHandling, .decrypting)
            XCTAssertTrue(connects.filter { $0.id == connect.id }.allSatisfy { $0.httpsHandling == .decrypting })
            XCTAssertTrue(posts.filter { $0.id == relatedID }.allSatisfy {
                $0.relatedTransactionID == connect.id && $0.httpsHandling == .decrypting
            })
            XCTAssertLessThanOrEqual(firstHTTP.startedAt, try XCTUnwrap(connect.finishedAt))
            let connectFinalIndex = try XCTUnwrap(events.transactions.firstIndex { $0.id == connect.id && $0.finishedAt != nil })
            let httpIndex = try XCTUnwrap(events.transactions.firstIndex { $0.id == firstHTTP.id })
            XCTAssertLessThan(connectFinalIndex, httpIndex, "CONNECT 必须先完成，再发布独立 HTTP ID")
            assertOrderedSnapshots(events, final: connect)
        }
        XCTAssertEqual(finals.first?.rewrittenHeaders, ["X-Replace", "X-Added", "X-Second"])
        XCTAssertEqual(finals.last?.rewrittenHeaders, [])
        XCTAssertTrue(events.serverFailures.isEmpty, "非法客户端不能发 server failed")
    }
    private func assertClosedTimings(_ transaction: CustomsTransaction, phases: [CustomsRequestPhase],
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(transaction.phaseTimings.map(\.phase), phases, file: file, line: line)
        XCTAssertEqual(Set(transaction.phaseTimings.map(\.phase)).count, phases.count, file: file, line: line)
        let finish = try XCTUnwrap(transaction.finishedAt, file: file, line: line)
        for (index, timing) in transaction.phaseTimings.enumerated() {
            let end = try XCTUnwrap(timing.finishedAt, file: file, line: line)
            XCTAssertGreaterThanOrEqual(end, timing.startedAt, file: file, line: line)
            XCTAssertGreaterThanOrEqual(timing.duration, 0, file: file, line: line)
            XCTAssertTrue(timing.duration.isFinite, file: file, line: line)
            XCTAssertLessThanOrEqual(end, finish, file: file, line: line)
            if index + 1 < transaction.phaseTimings.count {
                XCTAssertEqual(end, transaction.phaseTimings[index + 1].startedAt, file: file, line: line)
            } else {
                XCTAssertEqual(end, finish, file: file, line: line)
            }
            XCTAssertFalse(timing.phase.title.isEmpty, file: file, line: line)
            XCTAssertFalse(timing.phase.detail.isEmpty, file: file, line: line)
        }
    }
    private func assertOrderedSnapshots(_ events: Events, final: CustomsTransaction,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let updates = events.transactions.filter { $0.id == final.id }
        XCTAssertEqual(updates.filter { $0.finishedAt != nil }.count, 1, file: file, line: line)
        XCTAssertEqual(updates.last?.finishedAt, final.finishedAt, "最终事件后不能再发布旧快照", file: file, line: line)
        XCTAssertEqual(updates.last?.phase, final.phase, file: file, line: line)
        let recorded = final.phaseTimings.map(\.phase)
        let ordered = (recorded.first == .captured ? [] : [.captured]) + recorded + (final.error == nil ? [.completed] : [])
        var previous = -1
        var bodyComplete = false
        var bodyCount = 0
        var responseCount = 0
        var sawStatus = false
        for update in updates {
            guard let index = ordered.firstIndex(of: update.phase) else {
                XCTFail("未记录的阶段: \(update.phase)", file: file, line: line); continue
            }
            XCTAssertGreaterThanOrEqual(index, previous, "阶段不能回退", file: file, line: line)
            previous = index
            if bodyComplete { XCTAssertTrue(update.requestBodyComplete, file: file, line: line) }
            bodyComplete = update.requestBodyComplete
            XCTAssertGreaterThanOrEqual(update.requestBody.count, bodyCount, file: file, line: line)
            bodyCount = update.requestBody.count
            XCTAssertGreaterThanOrEqual(update.responseByteCount, responseCount, file: file, line: line)
            responseCount = update.responseByteCount
            if sawStatus { XCTAssertEqual(update.statusCode, final.statusCode, file: file, line: line) }
            sawStatus = update.statusCode != nil
        }
    }
    func testPlainPOSTPublishesPartialAndCompleteUploadBeforeGatedOriginResponse() throws {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let firstReceived = DispatchSemaphore(value: 0), uploaded = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        defer { releaseResponse.signal() }
        // A one-byte first segment makes the first capture event deterministic even with fragmented TCP reads.
        let first = Data([0]), second = Data([255, 13, 10, 128]) + Data("second upload segment".utf8)
        let body = first + second
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin)
                let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(transport)
                let head = try reader.head()
                XCTAssertEqual(head.firstLine, "POST /live%2Fupload HTTP/1.1")
                XCTAssertEqual(head.values("content-length"), [String(body.count)])
                XCTAssertEqual(head.values("x-live"), ["captured"])
                XCTAssertEqual(try reader.exact(first.count), first)
                firstReceived.signal()
                XCTAssertEqual(try reader.exact(second.count), second)
                uploaded.signal()
                guard releaseResponse.wait(timeout: .now() + 5) == .success else {
                    XCTFail("未释放源站响应"); return
                }
                try transport.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
            } catch { XCTFail("实时上传源站: \(error)") }
        }
        let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
        try client.write(Data("POST http://127.0.0.1:\(originPort)/live%2Fupload HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nContent-Length: \(body.count)\r\nX-Live: captured\r\n\r\n".utf8))
        let initial = try XCTUnwrap(events.waitForTransaction { $0.method == "POST" && $0.phase == .captured })
        XCTAssertEqual(events.transactions.first?.id, initial.id)
        XCTAssertTrue(initial.requestBody.isEmpty); XCTAssertFalse(initial.requestBodyComplete)
        XCTAssertNil(initial.statusCode); XCTAssertNil(initial.finishedAt)
        XCTAssertEqual(initial.originalRequestHeaders.first { $0.name.lowercased() == "x-live" }?.value, "captured")
        try client.write(first)
        XCTAssertEqual(firstReceived.wait(timeout: .now() + 5), .success)
        let partial = try XCTUnwrap(events.waitForTransaction { $0.id == initial.id && $0.requestBody == first })
        XCTAssertEqual(partial.phase, .sendingRequest)
        XCTAssertFalse(partial.requestBodyComplete); XCTAssertNil(partial.finishedAt); XCTAssertNil(partial.statusCode)
        try client.write(second)
        XCTAssertEqual(uploaded.wait(timeout: .now() + 5), .success)
        let complete = try XCTUnwrap(events.waitForTransaction { $0.id == initial.id && $0.requestBodyComplete })
        XCTAssertEqual(complete.requestBody, body); XCTAssertEqual(complete.phase, .waitingResponse)
        XCTAssertFalse(complete.requestBodyIncomplete); XCTAssertFalse(complete.requestBodyTruncated)
        XCTAssertNil(complete.finishedAt); XCTAssertNil(complete.statusCode)
        XCTAssertTrue(events.transactions.allSatisfy { $0.finishedAt == nil && $0.statusCode == nil })
        releaseResponse.signal()
        XCTAssertEqual(try reader.head().status, 200); XCTAssertEqual(try reader.exact(2), Data("ok".utf8))
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let final = try finalTransaction(events, method: "POST")
        XCTAssertEqual(final.requestBody, body); XCTAssertTrue(final.requestBodyComplete)
        XCTAssertEqual(final.phase, .completed); XCTAssertNil(final.error)
        try assertClosedTimings(final, phases: [.dns, .connecting, .sendingRequest, .waitingResponse, .receivingResponse])
        proxy.stop(); XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
        assertOrderedSnapshots(events, final: final)
    }
    func testEarly200And403KeepReceivingPhaseWhenUploadCompletes() throws {
        for status in [200, 403] {
            let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
            let originPort = origin.localPort, proxyPort = try Self.reservedPort()
            let releaseResponse = DispatchSemaphore(value: 0), uploaded = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            defer { releaseResponse.signal() }
            let first = Data([0, 255, 128]), second = Data("remaining upload".utf8), responseBody = Data("early response".utf8)
            let body = first + second
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    let socket = try Self.accepted(origin)
                    let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                    let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(transport)
                    let head = try reader.head()
                    XCTAssertEqual(head.firstLine, "POST /early-live HTTP/1.1")
                    XCTAssertEqual(try reader.exact(first.count), first)
                    let reason = status == 200 ? "OK" : "Forbidden"
                    try transport.write(Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(responseBody.count)\r\n\r\n".utf8))
                    XCTAssertEqual(try reader.exact(second.count), second)
                    uploaded.signal()
                    guard releaseResponse.wait(timeout: .now() + 5) == .success else {
                        XCTFail("未释放提前响应正文"); return
                    }
                    try transport.write(responseBody)
                } catch { XCTFail("提前响应源站: \(error)") }
            }
            let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
            try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
            XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
            let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
            let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
            let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
            try client.write(Data("POST http://127.0.0.1:\(originPort)/early-live HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
            try client.write(first)
            XCTAssertEqual(try reader.head().status, status)
            let receiving = try XCTUnwrap(events.waitForTransaction { $0.method == "POST" && $0.phase == .receivingResponse })
            XCTAssertEqual(receiving.statusCode, status); XCTAssertFalse(receiving.requestBodyComplete)
            XCTAssertNil(receiving.finishedAt)
            try client.write(second)
            XCTAssertEqual(uploaded.wait(timeout: .now() + 5), .success)
            let complete = try XCTUnwrap(events.waitForTransaction { $0.id == receiving.id && $0.requestBodyComplete })
            XCTAssertEqual(complete.phase, .receivingResponse, "上传完成不能把已开始响应的阶段退回 waitingResponse")
            XCTAssertEqual(complete.requestBody, body); XCTAssertEqual(complete.statusCode, status)
            XCTAssertNil(complete.finishedAt)
            releaseResponse.signal()
            XCTAssertEqual(try reader.exact(responseBody.count), responseBody)
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            let final = try finalTransaction(events, method: "POST")
            XCTAssertNil(final.error); XCTAssertFalse(final.requestBodyIncomplete); XCTAssertTrue(final.requestBodyComplete)
            XCTAssertEqual(final.responseBody, responseBody); XCTAssertEqual(final.phase, .completed)
            try assertClosedTimings(final, phases: [.dns, .connecting, .sendingRequest, .receivingResponse])
            proxy.stop(); XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
            assertOrderedSnapshots(events, final: final)
            let updates = events.transactions.filter { $0.id == final.id }
            let responseIndex = try XCTUnwrap(updates.firstIndex { $0.statusCode != nil })
            XCTAssertTrue(updates[responseIndex...].allSatisfy { $0.phase == .receivingResponse || $0.phase == .completed })
        }
    }
    func testBodylessGETAndPOSTPublishCompleteBeforeResponseAndOrderedHTTPPhases() throws {
        for method in ["GET", "POST"] {
            let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
            let originPort = origin.localPort, proxyPort = try Self.reservedPort()
            let headersReceived = DispatchSemaphore(value: 0), releaseResponse = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            defer { releaseResponse.signal() }
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    let socket = try Self.accepted(origin)
                    let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                    let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(transport)
                    let head = try reader.head()
                    XCTAssertEqual(head.firstLine, "\(method) /no-body HTTP/1.1")
                    XCTAssertTrue(head.values("content-length").isEmpty); XCTAssertTrue(head.values("transfer-encoding").isEmpty)
                    XCTAssertEqual(try CustomsHTTP.framing(head), .none)
                    headersReceived.signal()
                    guard releaseResponse.wait(timeout: .now() + 5) == .success else {
                        XCTFail("未释放无正文请求响应"); return
                    }
                    try transport.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
                } catch { XCTFail("无请求正文源站: \(error)") }
            }
            let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
            try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
            XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
            let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
            let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
            let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
            try client.write(Data("\(method) http://127.0.0.1:\(originPort)/no-body HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
            XCTAssertEqual(headersReceived.wait(timeout: .now() + 5), .success)
            let waiting = try XCTUnwrap(events.waitForTransaction { $0.method == method && $0.phase == .waitingResponse })
            XCTAssertTrue(waiting.requestBodyComplete); XCTAssertTrue(waiting.requestBody.isEmpty)
            XCTAssertNil(waiting.statusCode); XCTAssertNil(waiting.finishedAt)
            let initial = try XCTUnwrap(events.transactions.first)
            XCTAssertEqual(initial.phase, .captured); XCTAssertTrue(initial.requestBodyComplete)
            releaseResponse.signal()
            XCTAssertEqual(try reader.head().status, 200); XCTAssertEqual(try reader.exact(2), Data("ok".utf8))
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            let final = try finalTransaction(events, method: method)
            XCTAssertTrue(final.requestBodyComplete); XCTAssertFalse(final.requestBodyIncomplete)
            XCTAssertEqual(final.phase, .completed); XCTAssertNil(final.error)
            try assertClosedTimings(final, phases: [.dns, .connecting, .sendingRequest, .waitingResponse, .receivingResponse])
            proxy.stop(); XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
            assertOrderedSnapshots(events, final: final)
        }
    }
    func testEveryRequestPhaseHasDistinctTitleAndDetail() {
        let phases: [CustomsRequestPhase] = [.captured, .dns, .connecting, .certificate, .upstreamTLS,
                                            .clientTLS, .clientRequest, .sendingRequest, .waitingResponse,
                                            .receivingResponse, .tunnel, .completed]
        XCTAssertEqual(Set(phases.map(\.rawValue)).count, 12)
        XCTAssertEqual(Set(phases.map(\.title)).count, 12)
        XCTAssertEqual(Set(phases.map(\.detail)).count, 12)
        for phase in phases {
            XCTAssertFalse(phase.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(phase.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    func testModelPhaseTimingsClosePriorRecordAndCompleteWithoutDuplicates() throws {
        let zero = Date(timeIntervalSince1970: 0)
        var transaction = CustomsTransaction(startedAt: zero, method: "GET", url: "http://127.0.0.1/")
        transaction.advance(to: .captured, at: zero)
        transaction.advance(to: .dns, at: zero.addingTimeInterval(1))
        transaction.advance(to: .dns, at: zero.addingTimeInterval(2))
        XCTAssertEqual(transaction.phaseTimings.count, 2)
        XCTAssertEqual(transaction.phaseTimings[0].finishedAt, zero.addingTimeInterval(1))
        XCTAssertNil(transaction.phaseTimings[1].finishedAt)
        transaction.advance(to: .connecting, at: zero.addingTimeInterval(3))
        XCTAssertEqual(transaction.phaseTimings[1].finishedAt, zero.addingTimeInterval(3))
        transaction.finishTiming(at: zero.addingTimeInterval(5))
        XCTAssertEqual(transaction.phase, .completed); XCTAssertNil(transaction.error)
        XCTAssertEqual(transaction.phaseTimings.map(\.duration), [1, 2, 2])
        try assertClosedTimings(transaction, phases: [.captured, .dns, .connecting])
        transaction.advance(to: .receivingResponse, at: zero.addingTimeInterval(6))
        transaction.advance(to: .completed, at: zero.addingTimeInterval(7))
        XCTAssertEqual(transaction.phase, .completed); XCTAssertEqual(transaction.finishedAt, zero.addingTimeInterval(5))
        XCTAssertEqual(transaction.phaseTimings.map(\.duration), [1, 2, 2])
        XCTAssertEqual(transaction.phaseTimings.count, 3)
    }
    func testModelFailedConnectingPreservesPhaseAndClosesNonnegativeTimings() throws {
        let zero = Date(timeIntervalSince1970: 0)
        var transaction = CustomsTransaction(startedAt: zero, method: "GET", url: "http://127.0.0.1/")
        transaction.advance(to: .captured, at: zero)
        transaction.advance(to: .dns, at: zero.addingTimeInterval(1))
        transaction.advance(to: .connecting, at: zero.addingTimeInterval(3))
        transaction.error = "connection failed"
        transaction.finishTiming(at: zero.addingTimeInterval(5))
        XCTAssertEqual(transaction.phase, .connecting); XCTAssertEqual(transaction.error, "connection failed")
        XCTAssertEqual(transaction.phaseTimings.map(\.duration), [1, 2, 2])
        try assertClosedTimings(transaction, phases: [.captured, .dns, .connecting])
        transaction.advance(to: .waitingResponse, at: zero.addingTimeInterval(6))
        XCTAssertEqual(transaction.phase, .connecting); XCTAssertEqual(transaction.finishedAt, zero.addingTimeInterval(5))
        XCTAssertEqual(transaction.phaseTimings.count, 3)
        XCTAssertEqual(transaction.phaseTimings.map(\.duration), [1, 2, 2])
        let backwards = CustomsPhaseTiming(phase: .connecting, startedAt: zero.addingTimeInterval(3), finishedAt: zero)
        XCTAssertEqual(backwards.duration, 0)
        let instantaneous = CustomsPhaseTiming(phase: .dns, startedAt: zero, finishedAt: zero)
        XCTAssertEqual(instantaneous.duration, 0)
    }
    // Keep broken proxy implementations from leaving test reads at the transport's 30s timeout.
    private static func readDeadline(_ socket: CustomsSocket) -> DispatchWorkItem {
        let timeout = DispatchWorkItem { socket.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        return timeout
    }
    private func finalTransaction(_ events: Events, method: String) throws -> CustomsTransaction {
        _ = try XCTUnwrap(events.waitForTransaction { $0.method == method && $0.finishedAt != nil }, "未收到最终事件")
        let finals = events.transactions.filter { $0.method == method && $0.finishedAt != nil }
        XCTAssertEqual(finals.count, 1, "每个请求只能完成一次")
        XCTAssertTrue(events.serverFailures.isEmpty, "请求错误不是代理生命周期失败")
        return try XCTUnwrap(finals.first)
    }
    private func assertLocalResponse(_ head: CustomsHTTP.Head, body: Data, final: CustomsTransaction,
                                     isHEAD: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(head.status, 502, file: file, line: line)
        XCTAssertEqual(final.statusCode, head.status, file: file, line: line)
        XCTAssertTrue(final.responseIsLocal, file: file, line: line)
        XCTAssertEqual(final.responseHeaders.map { $0.name + ": " + $0.value },
                       head.headers.map { $0.name + ": " + $0.value }, file: file, line: line)
        XCTAssertEqual(final.responseBody, body, file: file, line: line)
        XCTAssertEqual(final.responseByteCount, body.count, file: file, line: line)
        XCTAssertFalse(final.responseBodyTruncated, file: file, line: line)
        let error = try XCTUnwrap(final.error, file: file, line: line)
        XCTAssertFalse(error.isEmpty, file: file, line: line)
        let length = try XCTUnwrap(head.values("content-length").first.flatMap { Int($0) }, file: file, line: line)
        XCTAssertGreaterThan(length, 0, file: file, line: line)
        if isHEAD {
            XCTAssertTrue(body.isEmpty, file: file, line: line)
        } else {
            XCTAssertEqual(length, body.count, file: file, line: line)
            XCTAssertFalse(body.isEmpty, file: file, line: line)
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(error), file: file, line: line)
        }
    }
    private func plainErrorResponse(method: String = "GET", originResponse: String?,
                                    body: Data = Data(), expectContinue: Bool = false,
                                    badChunk: Bool = false) throws -> (CustomsHTTP.Head, Data, CustomsTransaction) {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin)
                let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(transport)
                let request = try reader.head()
                XCTAssertEqual(request.firstLine, "\(method) /local-error HTTP/1.1")
                XCTAssertTrue(request.values("expect").isEmpty)
                if badChunk {
                    // The malformed upload must cancel only upstream, leaving client writable.
                    while !(try reader.block(maximum: 4096)).isEmpty {}
                } else {
                    let sink = MemoryTransport("")
                    try reader.forward(CustomsHTTP.framing(request), to: sink) { _ in }
                    XCTAssertEqual(sink.output, body)
                    if let originResponse { try transport.write(Data(originResponse.utf8)) }
                }
            } catch { XCTFail("本地错误源站: \(error)") }
        }
        let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
        let framing = badChunk ? "Transfer-Encoding: chunked\r\n" : (method == "POST" ? "Content-Length: \(body.count)\r\n" : "")
        try client.write(Data("\(method) http://127.0.0.1:\(originPort)/local-error HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\(framing)\(expectContinue ? "Expect: 100-continue\r\n" : "")\r\n".utf8))
        if expectContinue { XCTAssertEqual(try reader.head().status, 100) }
        if badChunk {
            try client.write(Data("3\r\nabc\r\nnot-hex\r\n".utf8))
        } else if !body.isEmpty {
            try client.write(body)
        }
        let response = try reader.head()
        var received = Data()
        try reader.forward(CustomsHTTP.framing(response, responseTo: method), to: MemoryTransport("")) { received.append($0) }
        XCTAssertTrue(try reader.block(maximum: 1).isEmpty, "本地最终响应后必须关闭，HEAD 不能发送正文")
        timeout.cancel(); socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        // Socket EOF may precede asynchronous delivery of the final transaction snapshot.
        let final = try finalTransaction(events, method: method)
        return (response, received, final)
    }
    func testOriginEOFBeforeHeadersReturnsCapturedLocal502() throws {
        let (head, body, final) = try plainErrorResponse(originResponse: nil)
        try assertLocalResponse(head, body: body, final: final)
        XCTAssertFalse(final.requestBodyIncomplete)
        XCTAssertTrue(final.requestBodyComplete)
        XCTAssertEqual(final.phase, .waitingResponse, "本地 502 不能覆盖源站 EOF 的失败阶段")
        try assertClosedTimings(final, phases: [.dns, .connecting, .sendingRequest, .waitingResponse])
    }
    func testConflictingOriginFramingReturnsLocal502InsteadOf200() throws {
        let (head, body, final) = try plainErrorResponse(originResponse: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
        try assertLocalResponse(head, body: body, final: final)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Content-Length"))
    }
    func testHEADOriginErrorsReturnLocal502WithLengthButNoWireBody() throws {
        let responses: [String?] = [nil, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n"]
        for response in responses {
            let (head, body, final) = try plainErrorResponse(method: "HEAD", originResponse: response)
            try assertLocalResponse(head, body: body, final: final, isHEAD: true)
            XCTAssertEqual(final.responseByteCount, 0)
            XCTAssertFalse(final.requestBodyIncomplete)
        }
    }
    func testCompletedExpectUploadReturns100ThenCapturedLocal502() throws {
        let payload = Data("completed upload".utf8)
        let (head, body, final) = try plainErrorResponse(method: "POST", originResponse: "NOT-HTTP\r\n\r\n", body: payload, expectContinue: true)
        try assertLocalResponse(head, body: body, final: final)
        XCTAssertEqual(final.requestBody, payload)
        XCTAssertFalse(final.requestBodyIncomplete)
        XCTAssertFalse(try XCTUnwrap(final.error).contains("上传失败"))
    }
    func testMalformedChunkUploadReturnsLocal502PreservingUploadFailure() throws {
        let (head, body, final) = try plainErrorResponse(method: "POST", originResponse: nil, badChunk: true)
        try assertLocalResponse(head, body: body, final: final)
        XCTAssertTrue(try XCTUnwrap(final.error).contains("上传失败"))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("上传失败"))
        XCTAssertTrue(final.requestBodyIncomplete)
        XCTAssertEqual(final.requestBody, Data("abc".utf8))
        XCTAssertFalse(final.canCopyCurl)
    }
    func testPartialOrigin200PreservesBodyAndNeverAppendsLocal502() throws {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin)
                let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(transport)
                XCTAssertEqual(try reader.head().firstLine, "GET /partial HTTP/1.1")
                try transport.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc".utf8))
            } catch { XCTFail("部分响应源站: \(error)") }
        }
        let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
        try client.write(Data("GET http://127.0.0.1:\(originPort)/partial HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        let head = try reader.head()
        XCTAssertEqual(head.status, 200); XCTAssertEqual(head.values("content-length"), ["5"])
        var received = Data()
        // Read to EOF rather than exact(5), so an injected error response cannot hide after abc.
        try reader.forward(.close, to: MemoryTransport("")) { received.append($0) }
        XCTAssertEqual(received, Data("abc".utf8))
        timeout.cancel(); socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let final = try finalTransaction(events, method: "GET")
        XCTAssertEqual(final.statusCode, 200)
        XCTAssertFalse(final.responseIsLocal)
        XCTAssertEqual(final.responseBody, received); XCTAssertEqual(final.responseByteCount, 3)
        XCTAssertEqual(final.responseHeaders.map { $0.name + ": " + $0.value }, head.headers.map { $0.name + ": " + $0.value })
        XCTAssertFalse(try XCTUnwrap(final.error).isEmpty)
        XCTAssertFalse(final.requestBodyIncomplete)
    }
    func testMITMRecordingPausedAfterClientHandshakeForwardsHTTPWithoutRelatedRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsPausedAfterTLS-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxyCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("proxy"))
        let originCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("origin"))
        try proxyCA.prepare(); try originCA.prepare()
        let proxyRoot = try rootCertificate(proxyCA), originRoot = try rootCertificate(originCA)
        let identity = try originCA.identity(for: "127.0.0.1")
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin)
                let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", identity: identity)
                try tls.handshake()
                let reader = CustomsHTTPReader(tls)
                XCTAssertEqual(try reader.head().firstLine, "GET /paused-after-handshake HTTP/1.1")
                try tls.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8))
                tls.closeGracefully()
            } catch { XCTFail("MITM 暂停录制源站: \(error)") }
        }
        let events = Events()
        let proxy = CustomsProxyServer(certificateAuthority: proxyCA, upstreamTrustAnchors: [originRoot]) { events.receive($0) }
        defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: true, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let plain = CustomsPlainTransport(socket)
        try plain.write(Data("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        XCTAssertEqual(try CustomsHTTPReader(plain).head().status, 200)
        // Both TLS hops trust only their temporary test roots, without changing system trust.
        let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", trustAnchors: [proxyRoot])
        try tls.handshake()
        // Synchronous recording update precedes every HTTP byte, so header capture sees false.
        proxy.setRecording(false)
        let requestSentAt = Date()
        try tls.write(Data("GET /paused-after-handshake HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        let reader = CustomsHTTPReader(tls), head = try reader.head()
        XCTAssertEqual(head.status, 200)
        var body = Data()
        try reader.forward(CustomsHTTP.framing(head, responseTo: "GET"), to: MemoryTransport("")) { body.append($0) }
        XCTAssertEqual(body, Data("ok".utf8), "暂停录制不能中断实际 HTTPS 转发")
        XCTAssertTrue(try reader.block(maximum: 1).isEmpty)
        XCTAssertFalse(socket.isCancelled, "超时取消不能伪装成正常 TLS EOF")
        timeout.cancel(); socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        // CONNECT finishes only after reading the HTTP head and sampling disabled recording.
        let connect = try finalTransaction(events, method: "CONNECT")
        XCTAssertEqual(connect.statusCode, 200); XCTAssertTrue(connect.isTunnel)
        XCTAssertNil(connect.error); XCTAssertFalse(connect.responseIsLocal)
        XCTAssertEqual(connect.phase, .completed)
        XCTAssertEqual(connect.httpsHandling, .decrypting)
        XCTAssertNil(connect.relatedTransactionID)
        XCTAssertTrue(connect.connectNotice.contains("未录制"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(connect.finishedAt), requestSentAt)
        try assertClosedTimings(connect, phases: [.dns, .connecting, .certificate, .upstreamTLS, .clientTLS, .clientRequest])
        proxy.stop()
        XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
        assertOrderedSnapshots(events, final: connect)
        let snapshots = events.transactions
        XCTAssertFalse(snapshots.contains { $0.method == "GET" }, "暂停后的解密 HTTP 请求不得发布任何录制事件")
        XCTAssertTrue(snapshots.allSatisfy { $0.method == "CONNECT" && $0.id == connect.id && $0.relatedTransactionID == nil })
        XCTAssertEqual(snapshots.filter { $0.finishedAt != nil }.count, 1)
        XCTAssertTrue(events.serverFailures.isEmpty)
    }
    func testMITMMalformedOriginHTTPReturnsDecryptedLocal502AndFinishesBothIDsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsLocalTLS502-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxyCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("proxy"))
        let originCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("origin"))
        try proxyCA.prepare(); try originCA.prepare()
        let proxyRoot = try rootCertificate(proxyCA), originRoot = try rootCertificate(originCA)
        let identity = try originCA.identity(for: "127.0.0.1")
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin)
                let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", identity: identity)
                try tls.handshake()
                let reader = CustomsHTTPReader(tls)
                XCTAssertEqual(try reader.head().firstLine, "GET /tls-local-error HTTP/1.1")
                try tls.write(Data("NOT-HTTP\r\n\r\n".utf8))
                tls.closeGracefully()
            } catch { XCTFail("MITM 本地错误源站: \(error)") }
        }
        let events = Events()
        let proxy = CustomsProxyServer(certificateAuthority: proxyCA, upstreamTrustAnchors: [originRoot]) { events.receive($0) }
        defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: true, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let plain = CustomsPlainTransport(socket)
        try plain.write(Data("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        XCTAssertEqual(try CustomsHTTPReader(plain).head().status, 200)
        // Explicit temporary anchors on both TLS hops; no system/keychain trust changes.
        let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", trustAnchors: [proxyRoot])
        try tls.handshake()
        try tls.write(Data("GET /tls-local-error HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        let reader = CustomsHTTPReader(tls), head = try reader.head()
        var body = Data()
        try reader.forward(CustomsHTTP.framing(head, responseTo: "GET"), to: MemoryTransport("")) { body.append($0) }
        XCTAssertTrue(try reader.block(maximum: 1).isEmpty, "TLS 本地响应后不能追加明文 HTTP")
        timeout.cancel(); socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        // events.finished also signals CONNECT; wait specifically for the decrypted HTTP final.
        let final = try finalTransaction(events, method: "GET")
        try assertLocalResponse(head, body: body, final: final)
        XCTAssertEqual(final.url, "https://127.0.0.1:\(originPort)/tls-local-error")
        XCTAssertFalse(final.isTunnel); XCTAssertFalse(final.requestBodyIncomplete)
        let connect = try finalTransaction(events, method: "CONNECT")
        XCTAssertEqual(connect.statusCode, 200); XCTAssertTrue(connect.isTunnel)
        XCTAssertNil(connect.error); XCTAssertFalse(connect.responseIsLocal)
        XCTAssertTrue(connect.responseBody.isEmpty); XCTAssertEqual(connect.responseByteCount, 0)
        XCTAssertNotEqual(connect.id, final.id)
        XCTAssertEqual(connect.relatedTransactionID, final.id)
        XCTAssertEqual(final.relatedTransactionID, connect.id)
        XCTAssertEqual(connect.httpsHandling, .decrypting)
        XCTAssertEqual(final.httpsHandling, .decrypting)
        let finals = events.transactions.filter { $0.finishedAt != nil }
        XCTAssertEqual(finals.count, 2)
        XCTAssertEqual(Set(finals.map(\.id)).count, 2)
    }
    func testMalformedUploadAfterFinalHeadersPreservesEntireLargeOriginResponse() throws {
        for status in [200, 413] {
            let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
            let originPort = origin.localPort, proxyPort = try Self.reservedPort()
            let releaseBody = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            // Release the origin even if client setup, header reading, or upload writing throws.
            defer { releaseBody.signal() }
            let payload = Data(repeating: 0x52, count: CustomsHTTP.captureLimit + 64 * 1024)
            let firstPart = 1024
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    let socket = try Self.accepted(origin)
                    let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                    let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(transport)
                    let request = try reader.head()
                    XCTAssertEqual(request.firstLine, "POST /late-bad-chunk HTTP/1.1")
                    XCTAssertEqual(request.values("transfer-encoding"), ["chunked"])
                    let reason = status == 200 ? "OK" : "Payload Too Large"
                    try transport.write(Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload.prefix(firstPart))
                    guard releaseBody.wait(timeout: .now() + 5) == .success else {
                        XCTFail("客户端未释放源站响应正文")
                        return
                    }
                    // Keep the upstream alive and stream bounded blocks after final headers.
                    var offset = firstPart
                    while offset < payload.count {
                        let end = min(offset + 64 * 1024, payload.count)
                        try transport.write(Data(payload[offset..<end]))
                        offset = end
                    }
                } catch { XCTFail("最终响应后的非法上传源站: \(error)") }
            }
            let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
            try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
            XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
            let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
            let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
            let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
            try client.write(Data("POST http://127.0.0.1:\(originPort)/late-bad-chunk HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            let head = try reader.head()
            XCTAssertEqual(head.status, status)
            XCTAssertEqual(head.values("content-length"), [String(payload.count)])
            // Reading final headers proves markFinalResponse won before this upload failure.
            try client.write(Data("not-hex\r\n".utf8))
            releaseBody.signal()
            var received = Data()
            try reader.forward(CustomsHTTP.framing(head, responseTo: "POST"), to: MemoryTransport("")) { received.append($0) }
            XCTAssertEqual(received, payload, "非法上传不能取消已经开始的源站最终响应")
            XCTAssertTrue(try reader.block(maximum: 1).isEmpty, "不能追加本地 502")
            timeout.cancel(); socket.cancel()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            let final = try finalTransaction(events, method: "POST")
            XCTAssertEqual(final.statusCode, status); XCTAssertNil(final.error)
            XCTAssertTrue(final.requestBodyIncomplete); XCTAssertTrue(final.requestBody.isEmpty)
            XCTAssertFalse(final.responseIsLocal); XCTAssertFalse(final.canCopyCurl)
            XCTAssertEqual(final.responseByteCount, payload.count)
            XCTAssertEqual(final.responseBody, Data(payload.prefix(CustomsHTTP.captureLimit)))
            XCTAssertTrue(final.responseBodyTruncated)
            XCTAssertEqual(final.responseHeaders.map { $0.name + ": " + $0.value }, head.headers.map { $0.name + ": " + $0.value })
        }
    }
    func testMITMConflictingDecryptedRequestFramingReturnsLocal502WithoutUpstreamHTTP() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsInvalidRequestTLS-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxyCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("proxy"))
        let originCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("origin"))
        try proxyCA.prepare(); try originCA.prepare()
        let proxyRoot = try rootCertificate(proxyCA), originRoot = try rootCertificate(originCA)
        let identity = try originCA.identity(for: "127.0.0.1")
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin)
                let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", identity: identity)
                try tls.handshake()
                var received = Data()
                do {
                    while true {
                        let bytes = try tls.read(maximum: 4096)
                        if bytes.isEmpty { break }
                        received.append(bytes)
                    }
                } catch {
                    // Upstream cancellation may omit close_notify; only TLS close errors are expected.
                    let message = error.localizedDescription
                    XCTAssertFalse(socket.isCancelled, "不能将五秒超时取消误当成预期 EOF")
                    XCTAssertTrue(message.contains("OSStatus \(errSSLClosedNoNotify)") || message.contains("OSStatus \(errSSLClosedAbort)"), "非预期源站 TLS 读取错误: \(error)")
                }
                XCTAssertTrue(received.isEmpty, "framing 校验失败的解密请求头不得写入上游")
            } catch { XCTFail("MITM 非法请求 framing 源站: \(error)") }
        }
        let events = Events()
        let proxy = CustomsProxyServer(certificateAuthority: proxyCA, upstreamTrustAnchors: [originRoot]) { events.receive($0) }
        defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: true, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let plain = CustomsPlainTransport(socket)
        try plain.write(Data("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
        XCTAssertEqual(try CustomsHTTPReader(plain).head().status, 200)
        let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", trustAnchors: [proxyRoot])
        try tls.handshake()
        try tls.write(Data("POST /invalid-framing HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        let reader = CustomsHTTPReader(tls), head = try reader.head()
        var body = Data()
        try reader.forward(CustomsHTTP.framing(head, responseTo: "POST"), to: MemoryTransport("")) { body.append($0) }
        XCTAssertTrue(try reader.block(maximum: 1).isEmpty)
        timeout.cancel(); socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        // Wait for POST, never consume the CONNECT completion as the HTTP final.
        let final = try finalTransaction(events, method: "POST")
        try assertLocalResponse(head, body: body, final: final)
        XCTAssertTrue(try XCTUnwrap(final.error).contains("Content-Length"))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Content-Length"))
        XCTAssertTrue(final.requestBodyIncomplete); XCTAssertTrue(final.requestBody.isEmpty)
        XCTAssertFalse(final.isTunnel); XCTAssertFalse(final.canCopyCurl)
        XCTAssertEqual(final.url, "https://127.0.0.1:\(originPort)/invalid-framing")
        let connect = try finalTransaction(events, method: "CONNECT")
        XCTAssertEqual(connect.statusCode, 200); XCTAssertNil(connect.error)
        XCTAssertTrue(connect.isTunnel); XCTAssertFalse(connect.responseIsLocal)
        XCTAssertNotEqual(connect.id, final.id)
        XCTAssertEqual(connect.relatedTransactionID, final.id)
        XCTAssertEqual(final.relatedTransactionID, connect.id)
        XCTAssertEqual(connect.httpsHandling, .decrypting)
        XCTAssertEqual(final.httpsHandling, .decrypting)
        let finals = events.transactions.filter { $0.finishedAt != nil }
        XCTAssertEqual(finals.count, 2); XCTAssertEqual(Set(finals.map(\.id)).count, 2)
    }
    func testOptionsAsteriskDestinationAndTunnelAuthorityContract() throws {
        let authorities: [(String, String, UInt16)] = [
            ("example.test", "example.test", 80),
            ("example.test:8080", "example.test", 8080),
            ("[::1]:8080", "::1", 8080)
        ]
        for (authority, host, port) in authorities {
            let head = try CustomsHTTPReader(MemoryTransport("OPTIONS * HTTP/1.1\r\nHost: \(authority)\r\n\r\n")).head()
            let destination = try CustomsHTTP.destination(head)
            XCTAssertEqual(destination.method, "OPTIONS"); XCTAssertEqual(destination.target, "*")
            XCTAssertEqual(destination.host, host); XCTAssertEqual(destination.port, port)
            XCTAssertEqual(destination.url, "http://\(authority)/")
            XCTAssertNotNil(URL(string: destination.url)?.host)
            var transaction = CustomsTransaction(method: destination.method, url: destination.url)
            transaction.requestTarget = destination.target
            XCTAssertEqual(transaction.path, "*")
        }
        for headers in ["", "Host: example.test\r\nHost: example.test\r\n", "Host: bad/host\r\n",
                        "Host: user@example.test\r\n", "Host: example.test:0\r\n", "Host: ::1\r\n"] {
            let head = try CustomsHTTPReader(MemoryTransport("OPTIONS * HTTP/1.1\r\n\(headers)\r\n")).head()
            XCTAssertThrowsError(try CustomsHTTP.destination(head), headers)
        }
        for method in ["GET", "POST", "HEAD", "DELETE"] {
            let head = try CustomsHTTPReader(MemoryTransport("\(method) * HTTP/1.1\r\nHost: example.test:443\r\n\r\n")).head()
            XCTAssertThrowsError(try CustomsHTTP.destination(head))
            XCTAssertThrowsError(try CustomsHTTP.destination(head, tunnel: ("example.test", 443)))
        }
        for (authority, host, port) in [("example.test", "example.test", UInt16(443)),
                                      ("example.test:8443", "example.test", UInt16(8443)),
                                      ("[::1]:8443", "::1", UInt16(8443))] {
            let head = try CustomsHTTPReader(MemoryTransport("OPTIONS * HTTP/1.1\r\nHost: \(authority)\r\n\r\n")).head()
            let destination = try CustomsHTTP.destination(head, tunnel: (host, port))
            XCTAssertEqual(destination.target, "*"); XCTAssertEqual(destination.method, "OPTIONS")
            XCTAssertEqual(destination.host, host); XCTAssertEqual(destination.port, port)
            XCTAssertEqual(destination.url, "https://\(authority)/")
            XCTAssertNotNil(URL(string: destination.url)?.host)
            var transaction = CustomsTransaction(method: destination.method, url: destination.url)
            transaction.requestTarget = destination.target
            XCTAssertEqual(transaction.path, "*")
            XCTAssertThrowsError(try CustomsHTTP.destination(head, tunnel: ("wrong.test", port)))
            XCTAssertThrowsError(try CustomsHTTP.destination(head, tunnel: (host, port == 443 ? 8443 : 443)))
        }
        for headers in ["", "Host: example.test\r\nHost: example.test\r\n", "Host: bad/host\r\n"] {
            let head = try CustomsHTTPReader(MemoryTransport("OPTIONS * HTTP/1.1\r\n\(headers)\r\n")).head()
            XCTAssertThrowsError(try CustomsHTTP.destination(head, tunnel: ("example.test", 443)))
        }
    }
    func testOptionsAsteriskCurlUsesRequestTargetAndValidURL() throws {
        for scheme in ["http", "https"] {
            var transaction = CustomsTransaction(method: "OPTIONS", url: "\(scheme)://example.test:8443/")
            XCTAssertNil(transaction.requestTarget)
            transaction.requestTarget = "*"; transaction.finishedAt = Date()
            XCTAssertEqual(transaction.path, "*"); XCTAssertTrue(transaction.canCopyCurl)
            let curl = try XCTUnwrap(transaction.curl())
            XCTAssertTrue(curl.contains("--request-target '*'"))
            XCTAssertTrue(curl.contains("'\(scheme)://example.test:8443/'"))
            XCTAssertFalse(curl.contains("example.test:8443*"))
            XCTAssertNotNil(URL(string: transaction.url)?.host)
        }
    }
    private static let preflightOrigin = "https://browser.example.test"
    private static let preflightRequestHeaders = "Origin: https://browser.example.test\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: authorization, content-type, x-rewrite\r\n"
    private static let preflightResponseHeaders = "Access-Control-Allow-Origin: https://browser.example.test\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: authorization, content-type, x-rewrite\r\nAccess-Control-Allow-Credentials: true\r\nVary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\nAccess-Control-Max-Age: 600\r\n"
    private func assertPreflightCORS(_ head: CustomsHTTP.Head, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(head.values("access-control-allow-origin"), [Self.preflightOrigin], file: file, line: line)
        XCTAssertEqual(head.values("access-control-allow-methods"), ["POST, OPTIONS"], file: file, line: line)
        XCTAssertEqual(head.values("access-control-allow-headers"), ["authorization, content-type, x-rewrite"], file: file, line: line)
        XCTAssertEqual(head.values("access-control-allow-credentials"), ["true"], file: file, line: line)
        XCTAssertEqual(head.values("vary"), ["Origin, Access-Control-Request-Method, Access-Control-Request-Headers"], file: file, line: line)
        XCTAssertEqual(head.values("access-control-max-age"), ["600"], file: file, line: line)
    }
    private func plainOptionsExchange(target: String, responseWire: String, expectedBody: Data) throws -> (CustomsHTTP.Head, CustomsTransaction) {
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(origin)
                let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                let transport = CustomsPlainTransport(socket), reader = CustomsHTTPReader(transport)
                let request = try reader.head()
                XCTAssertEqual(request.firstLine, "OPTIONS \(target) HTTP/1.1")
                XCTAssertEqual(request.values("host"), ["127.0.0.1:\(originPort)"])
                XCTAssertEqual(request.values("origin"), [Self.preflightOrigin])
                XCTAssertEqual(request.values("access-control-request-method"), ["POST"])
                XCTAssertEqual(request.values("access-control-request-headers"), ["authorization, content-type, x-rewrite"])
                XCTAssertEqual(try CustomsHTTP.framing(request), .none)
                try transport.write(Data(responseWire.utf8))
            } catch { XCTFail("OPTIONS 明文源站: \(error)") }
        }
        let events = Events(), proxy = CustomsProxyServer { events.receive($0) }; defer { proxy.stop() }
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: false, sslHosts: ["*"], rewriteEnabled: false, headerRules: []))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
        let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
        let client = CustomsPlainTransport(socket), reader = CustomsHTTPReader(client)
        let wireTarget = target == "*" ? "*" : "http://127.0.0.1:\(originPort)\(target)"
        try client.write(Data("OPTIONS \(wireTarget) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\(Self.preflightRequestHeaders)\r\n".utf8))
        let response = try reader.head()
        var body = Data()
        try reader.forward(CustomsHTTP.framing(response, responseTo: "OPTIONS"), to: MemoryTransport("")) { body.append($0) }
        XCTAssertEqual(body, expectedBody)
        XCTAssertEqual(response.values("connection"), ["close"])
        XCTAssertTrue(try reader.block(maximum: 1).isEmpty, "OPTIONS 最终响应必须关闭且不能追加本地响应")
        XCTAssertFalse(socket.isCancelled, "超时取消不是正常 EOF")
        timeout.cancel(); socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let final = try finalTransaction(events, method: "OPTIONS")
        XCTAssertEqual(final.method, "OPTIONS"); XCTAssertEqual(final.requestTarget, target)
        XCTAssertEqual(final.url, "http://127.0.0.1:\(originPort)\(target == "*" ? "/" : target)")
        XCTAssertNotNil(URL(string: final.url)?.host)
        if target == "*" { XCTAssertEqual(final.path, "*") }
        XCTAssertEqual(final.statusCode, response.status)
        XCTAssertFalse(final.responseIsLocal); XCTAssertFalse(final.isTunnel); XCTAssertNil(final.error)
        XCTAssertEqual(final.responseBody, expectedBody); XCTAssertEqual(final.responseByteCount, expectedBody.count)
        XCTAssertFalse(final.requestBodyIncomplete); XCTAssertTrue(final.requestBody.isEmpty)
        XCTAssertTrue(final.requestBodyComplete); XCTAssertEqual(final.phase, .completed)
        try assertClosedTimings(final, phases: [.dns, .connecting, .sendingRequest, .waitingResponse, .receivingResponse])
        proxy.stop()
        XCTAssertEqual(events.stopped.wait(timeout: .now() + 5), .success)
        assertOrderedSnapshots(events, final: final)
        XCTAssertTrue(final.canCopyCurl); XCTAssertNotNil(final.curl())
        XCTAssertEqual(final.responseHeaders.map { $0.name + ": " + $0.value }, response.headers.map { $0.name + ": " + $0.value })
        return (response, final)
    }
    func testPlainOptionsPreflightPreservesAllCORSWithoutFraming() throws {
        let (response, final) = try plainOptionsExchange(target: "/api?q=%2F", responseWire: "HTTP/1.1 204 No Content\r\n\(Self.preflightResponseHeaders)\r\n", expectedBody: Data())
        XCTAssertEqual(response.status, 204)
        XCTAssertEqual(try CustomsHTTP.framing(response, responseTo: "OPTIONS"), .none)
        XCTAssertTrue(response.values("content-length").isEmpty); XCTAssertTrue(response.values("transfer-encoding").isEmpty)
        assertPreflightCORS(response)
        XCTAssertEqual(final.responseByteCount, 0)
        let curl = try XCTUnwrap(final.curl())
        XCTAssertTrue(curl.contains("Origin: \(Self.preflightOrigin)"))
        XCTAssertTrue(curl.contains("Access-Control-Request-Method: POST"))
        XCTAssertTrue(curl.contains("Access-Control-Request-Headers: authorization, content-type, x-rewrite"))
        XCTAssertFalse(curl.contains("--request-target"))
    }
    func testPlainOptionsAsteriskPreservesAllowAndResponseBodyWithoutInventingCORS() throws {
        let body = Data("server-wide capabilities".utf8)
        let (response, final) = try plainOptionsExchange(target: "*", responseWire: "HTTP/1.1 200 OK\r\nAllow: GET, HEAD, POST, OPTIONS\r\nContent-Length: \(body.count)\r\n\r\n\(String(decoding: body, as: UTF8.self))", expectedBody: body)
        XCTAssertEqual(response.status, 200); XCTAssertEqual(response.values("allow"), ["GET, HEAD, POST, OPTIONS"])
        XCTAssertEqual(response.values("content-length"), [String(body.count)])
        XCTAssertFalse(response.fields.contains { $0.name.lowercased().hasPrefix("access-control-") })
        XCTAssertTrue(try XCTUnwrap(final.curl()).contains("--request-target '*'"))
    }
    func testOriginOptions403PreservesDenialBodyWithoutFabricatedCORS() throws {
        let body = Data("preflight denied".utf8)
        let (response, final) = try plainOptionsExchange(target: "/api?q=%2F", responseWire: "HTTP/1.1 403 Forbidden\r\nContent-Length: \(body.count)\r\n\r\n\(String(decoding: body, as: UTF8.self))", expectedBody: body)
        XCTAssertEqual(response.status, 403); XCTAssertEqual(final.statusCode, 403)
        XCTAssertFalse(response.fields.contains { $0.name.lowercased().hasPrefix("access-control-") })
        XCTAssertTrue(response.values("allow").isEmpty)
    }

    private func mitmOptionsSequence(targets: [String], methods: [String]) throws {
        XCTAssertEqual(targets.count, methods.count)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsOptionsTLS-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxyCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("proxy"))
        let originCA = CustomsCertificateAuthority(directory: directory.appendingPathComponent("origin"))
        try proxyCA.prepare(); try originCA.prepare()
        let proxyRoot = try rootCertificate(proxyCA), originRoot = try rootCertificate(originCA)
        let identity = try originCA.identity(for: "127.0.0.1")
        let origin = try CustomsSocket.listen(port: 0, lan: false); defer { origin.cancel() }
        let originPort = origin.localPort, proxyPort = try Self.reservedPort()
        let done = DispatchSemaphore(value: 0)
        let payload = Data("{\"message\":\"actual POST after preflight\"}".utf8)
        // One listener accepts sequential connections; Connection: close forbids TLS reuse.
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                for (index, method) in methods.enumerated() {
                    let socket = try Self.accepted(origin)
                    let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
                    let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", identity: identity)
                    try tls.handshake()
                    let reader = CustomsHTTPReader(tls), request = try reader.head()
                    XCTAssertEqual(request.firstLine, "\(method) \(targets[index]) HTTP/1.1")
                    XCTAssertEqual(request.values("host"), ["127.0.0.1:\(originPort)"])
                    XCTAssertEqual(request.values("origin"), [Self.preflightOrigin])
                    XCTAssertEqual(request.values("x-rewrite"), ["changed"])
                    XCTAssertEqual(request.values("swimlane"), ["options-test"])
                    let sink = MemoryTransport("")
                    try reader.forward(CustomsHTTP.framing(request), to: sink) { _ in }
                    if method == "OPTIONS" {
                        XCTAssertEqual(request.values("access-control-request-method"), ["POST"])
                        XCTAssertEqual(request.values("access-control-request-headers"), ["authorization, content-type, x-rewrite"])
                        XCTAssertTrue(request.values("authorization").isEmpty)
                        XCTAssertEqual(try CustomsHTTP.framing(request), .none)
                        XCTAssertTrue(sink.output.isEmpty)
                        try tls.write(Data("HTTP/1.1 204 No Content\r\n\(Self.preflightResponseHeaders)\r\n".utf8))
                    } else {
                        XCTAssertEqual(method, "POST")
                        XCTAssertTrue(request.values("access-control-request-method").isEmpty)
                        XCTAssertTrue(request.values("access-control-request-headers").isEmpty)
                        XCTAssertEqual(request.values("authorization"), ["Bearer local-test-token"])
                        XCTAssertEqual(request.values("content-type"), ["application/json"])
                        XCTAssertEqual(request.values("content-length"), [String(payload.count)])
                        XCTAssertEqual(sink.output, payload)
                        try tls.write(Data("HTTP/1.1 200 OK\r\n\(Self.preflightResponseHeaders)Content-Length: \(payload.count)\r\nContent-Type: application/json\r\n\r\n".utf8) + payload)
                    }
                    tls.closeGracefully()
                }
            } catch { XCTFail("OPTIONS/POST TLS 源站: \(error)") }
        }
        let events = Events()
        let proxy = CustomsProxyServer(certificateAuthority: proxyCA, upstreamTrustAnchors: [originRoot]) { events.receive($0) }
        defer { proxy.stop() }
        let rules = [CustomsHeaderRule(id: UUID(), isEnabled: true, name: "X-Rewrite", value: "changed"),
                     CustomsHeaderRule(id: UUID(), isEnabled: true, name: "swimlane", value: "options-test")]
        try proxy.start(configuration: .init(port: proxyPort, listenOnLAN: false, decryptHTTPS: true, sslHosts: ["*"], rewriteEnabled: true, headerRules: rules))
        XCTAssertEqual(events.started.wait(timeout: .now() + 5), .success)
        var completedIDs: [UUID] = []
        for (index, method) in methods.enumerated() {
            // A browser sends the actual request on a new CONNECT after observing EOF.
            let socket = try CustomsSocket.connect(host: "127.0.0.1", port: proxyPort, proxyPort: 0) { _ in }
            let timeout = Self.readDeadline(socket); defer { timeout.cancel(); socket.cancel() }
            let plain = CustomsPlainTransport(socket)
            try plain.write(Data("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8))
            XCTAssertEqual(try CustomsHTTPReader(plain).head().status, 200)
            // Explicit anchors on both TLS hops; no trust bypass or system trust changes.
            let tls = try CustomsTLSTransport(socket: socket, host: "127.0.0.1", trustAnchors: [proxyRoot])
            try tls.handshake()
            let headers = method == "OPTIONS" ? Self.preflightRequestHeaders :
                "Origin: \(Self.preflightOrigin)\r\nAuthorization: Bearer local-test-token\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n"
            try tls.write(Data("\(method) \(targets[index]) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\(headers)X-Rewrite: old\r\nx-rewrite: duplicate\r\n\r\n".utf8))
            if method == "POST" { try tls.write(payload) }
            let reader = CustomsHTTPReader(tls), response = try reader.head()
            XCTAssertEqual(response.status, method == "OPTIONS" ? 204 : 200)
            assertPreflightCORS(response)
            XCTAssertEqual(response.values("connection"), ["close"])
            XCTAssertTrue(response.values("transfer-encoding").isEmpty)
            if method == "OPTIONS" {
                XCTAssertTrue(response.values("content-length").isEmpty)
                XCTAssertEqual(try CustomsHTTP.framing(response, responseTo: method), .none)
            }
            var body = Data()
            try reader.forward(CustomsHTTP.framing(response, responseTo: method), to: MemoryTransport("")) { body.append($0) }
            XCTAssertEqual(body, method == "OPTIONS" ? Data() : payload)
            XCTAssertTrue(try reader.block(maximum: 1).isEmpty, "必须收到 TLS EOF，不能复用声明 close 的连接")
            XCTAssertFalse(socket.isCancelled, "超时取消不能伪装成正常 TLS EOF")
            timeout.cancel(); socket.cancel()
            let final = try finalTransaction(events, method: method)
            completedIDs.append(final.id)
            XCTAssertEqual(final.method, method); XCTAssertEqual(final.requestTarget, targets[index])
            XCTAssertEqual(final.url, "https://127.0.0.1:\(originPort)\(targets[index] == "*" ? "/" : targets[index])")
            XCTAssertNotNil(URL(string: final.url)?.host)
            XCTAssertEqual(final.statusCode, response.status)
            XCTAssertFalse(final.responseIsLocal); XCTAssertFalse(final.isTunnel); XCTAssertNil(final.error)
            XCTAssertEqual(final.requestBody, method == "OPTIONS" ? Data() : payload)
            XCTAssertFalse(final.requestBodyIncomplete); XCTAssertFalse(final.requestBodyTruncated)
            XCTAssertEqual(final.responseBody, body); XCTAssertEqual(final.responseByteCount, body.count)
            XCTAssertFalse(final.responseBodyTruncated); XCTAssertTrue(final.canCopyCurl)
            XCTAssertEqual(final.rewrittenHeaders, ["X-Rewrite", "swimlane"])
            XCTAssertEqual(final.responseHeaders.map { $0.name + ": " + $0.value }, response.headers.map { $0.name + ": " + $0.value })
            XCTAssertEqual(final.requestHeaders.filter { $0.name.lowercased() == "origin" }.map(\.value), [Self.preflightOrigin])
            let curl = try XCTUnwrap(final.curl())
            XCTAssertTrue(curl.contains("Origin: \(Self.preflightOrigin)"))
            if targets[index] == "*" {
                XCTAssertEqual(final.path, "*")
                XCTAssertTrue(curl.contains("--request-target '*'"))
                XCTAssertTrue(curl.contains("'https://127.0.0.1:\(originPort)/'"))
            } else {
                XCTAssertFalse(curl.contains("--request-target"))
            }
            if method == "POST" {
                XCTAssertTrue(curl.contains("Authorization: Bearer local-test-token"))
                XCTAssertTrue(curl.contains(String(decoding: payload, as: UTF8.self)))
            } else {
                XCTAssertTrue(curl.contains("Access-Control-Request-Method: POST"))
                XCTAssertTrue(curl.contains("Access-Control-Request-Headers: authorization, content-type, x-rewrite"))
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let deadline = Date().addingTimeInterval(5)
        while events.transactions.filter({ $0.method == "CONNECT" && $0.finishedAt != nil }).count < methods.count && deadline.timeIntervalSinceNow > 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let finals = events.transactions.filter { $0.finishedAt != nil }
        let connects = finals.filter { $0.method == "CONNECT" }
        XCTAssertEqual(connects.count, methods.count)
        XCTAssertEqual(Set(events.transactions.filter { $0.method == "CONNECT" }.map(\.id)).count, methods.count)
        for connect in connects {
            XCTAssertTrue(connect.isTunnel); XCTAssertNil(connect.error)
            XCTAssertEqual(connect.statusCode, 200); XCTAssertFalse(connect.responseIsLocal)
            XCTAssertFalse(completedIDs.contains(connect.id))
        }
        XCTAssertEqual(finals.count, methods.count * 2)
        XCTAssertEqual(Set(finals.map(\.id)).count, methods.count * 2, "CONNECT 与解密请求各自只完成一次")
        XCTAssertEqual(Set(completedIDs).count, methods.count)
        XCTAssertTrue(events.serverFailures.isEmpty)
    }
    func testMITMOptionsPathAndAsteriskPreservePreflightCORSAndDistinctConnectIDs() throws {
        for target in ["/api?q=%2F", "*"] {
            try mitmOptionsSequence(targets: [target], methods: ["OPTIONS"])
        }
    }
    func testMITMBrowserPreflightThenActualPOSTUsesNewConnectAndPreservesRulesAndCORS() throws {
        try mitmOptionsSequence(targets: ["/api?q=%2F", "/api?q=%2F"], methods: ["OPTIONS", "POST"])
    }

    func testCurlReadableUTF8TextContract() throws {
        var transaction = CustomsTransaction(method: "POST", url: "https://example.test/a%2Fb")
        transaction.finishedAt = Date(); transaction.requestBody = Data("中文 'quoted'\nline".utf8)
        let curl = try XCTUnwrap(transaction.curl())
        XCTAssertTrue(curl.contains("--data-binary '"), "UTF8 无 NUL 正文应该使用可读字面量")
        XCTAssertTrue(curl.contains("中文")); XCTAssertFalse(curl.contains("base64"))
    }
    func testCurlBinaryAndPendingContract() throws {
        var transaction = CustomsTransaction(method: "POST", url: "https://example.test/")
        transaction.requestBody = Data([0, 255, 128, 39])
        XCTAssertFalse(transaction.canCopyCurl, "未完成上传不可复制 cURL")
        XCTAssertNil(transaction.curl())
        transaction.finishedAt = Date()
        let curl = try XCTUnwrap(transaction.curl())
        XCTAssertTrue(curl.contains(transaction.requestBody.base64EncodedString()))
        XCTAssertTrue(curl.contains("--data-binary @-")); XCTAssertFalse(curl.contains("\0"))
    }
    func testSocketCancellationAndTimeout() throws {
        let listener = try CustomsSocket.listen(port: 0, lan: false); defer { listener.cancel() }
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: listener.localPort, proxyPort: 0) { _ in }; defer { socket.cancel() }
        let peer = try Self.accepted(listener); defer { peer.cancel() }
        XCTAssertThrowsError(try socket.wait(Int16(POLLIN), deadline: Date().addingTimeInterval(0.03)))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { _ = try CustomsPlainTransport(socket).read(); XCTFail("取消后读取必须失败") }
            catch { /* Expected cancellation. */ }
        }
        socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }
    func testSuccessfulTLSStreamingWithoutSystemTrustChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsTLS-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        try ca.prepare(); let identity = try ca.identity(for: "localhost")
        let pem = try String(contentsOf: ca.certificateURL, encoding: .utf8)
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, XCTUnwrap(Data(base64Encoded: base64)) as CFData))
        let listener = try CustomsSocket.listen(port: 0, lan: false); defer { listener.cancel() }
        let done = DispatchSemaphore(value: 0)
        let payload = Data(repeating: 0xA5, count: 200_000)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(listener); defer { socket.cancel() }
                let server = try CustomsTLSTransport(socket: socket, host: "localhost", identity: identity)
                try server.handshake()
                let reader = CustomsHTTPReader(server)
                let head = try reader.head(); XCTAssertEqual(head.firstLine, "POST /tls%2Fraw HTTP/1.1")
                let sink = MemoryTransport("")
                try reader.forward(CustomsHTTP.framing(head), to: sink) { _ in }
                XCTAssertEqual(sink.output, payload)
                try server.write(Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\n\r\n".utf8))
                try server.write(payload); server.closeGracefully()
            } catch { XCTFail("本地 TLS 源站: \(error)") }
        }
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: listener.localPort, proxyPort: 0) { _ in }; defer { socket.cancel() }
        let client = try CustomsTLSTransport(socket: socket, host: "localhost", trustAnchors: [root])
        try client.handshake()
        try client.write(Data("POST /tls%2Fraw HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(payload.count)\r\n\r\n".utf8))
        try client.write(payload)
        let reader = CustomsHTTPReader(client); let head = try reader.head()
        XCTAssertEqual(head.status, 200)
        var received = Data()
        try reader.forward(CustomsHTTP.framing(head, responseTo: "POST"), to: MemoryTransport("")) { received.append($0) }
        XCTAssertEqual(received, payload)
        XCTAssertTrue(try client.read(maximum: 1).isEmpty, "应收到 TLS close_notify 而非未通知 EOF")
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let start = Date()
        client.closeGracefully()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testCARegenerationAndExternalReplacementInvalidateLeaves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsCAReset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        let first = try ca.identity(for: "localhost")
        let oldRoot = try rootCertificate(ca)
        XCTAssertTrue(CFEqual(first, try ca.identity(for: "localhost")))
        let key = directory.appendingPathComponent("KriaCustomsCA.key")
        try FileManager.default.removeItem(at: ca.certificateURL)
        XCTAssertThrowsError(try ca.identity(for: "localhost"), "缺失 CA 不得返回旧缓存")
        try FileManager.default.removeItem(at: key)
        let regenerated = try ca.identity(for: "localhost")
        let newRoot = try rootCertificate(ca)
        XCTAssertFalse(CFEqual(oldRoot, newRoot))
        func trusted(_ identity: SecIdentity, by root: SecCertificate) throws -> Bool {
            var leaf: SecCertificate?
            XCTAssertEqual(SecIdentityCopyCertificate(identity, &leaf), errSecSuccess)
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates(try XCTUnwrap(leaf), SecPolicyCreateSSL(true, "localhost" as CFString), &trust), errSecSuccess)
            let value = try XCTUnwrap(trust)
            SecTrustSetAnchorCertificates(value, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(value, true)
            return SecTrustEvaluateWithError(value, nil)
        }
        XCTAssertTrue(try trusted(regenerated, by: newRoot))
        XCTAssertFalse(try trusted(regenerated, by: oldRoot))
        let replacement = CustomsCertificateAuthority(directory: directory.appendingPathComponent("replacement"))
        try replacement.prepare()
        try Data(contentsOf: replacement.certificateURL).write(to: ca.certificateURL)
        try Data(contentsOf: replacement.certificateURL.deletingLastPathComponent().appendingPathComponent("KriaCustomsCA.key")).write(to: key)
        try ca.prepare()
        let replaced = try ca.identity(for: "localhost")
        XCTAssertTrue(try trusted(replaced, by: rootCertificate(replacement)))
        XCTAssertFalse(try trusted(replaced, by: newRoot))
    }
    func testCombinedTransferEncodingPreservesWireButCannotCopyCurl() throws {
        let reader = CustomsHTTPReader(MemoryTransport("POST http://example.test/ HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: gzip, chunked\r\n\r\n3;ext=yes\r\nabc\r\n0\r\n\r\n"))
        let head = try reader.head(), sink = MemoryTransport("")
        var transaction = CustomsTransaction(method: "POST", url: "http://example.test/")
        transaction.requestHeaders = head.headers; transaction.originalRequestHeaders = head.headers
        try reader.forward(CustomsHTTP.framing(head), to: sink) { transaction.requestBody.append($0) }
        transaction.finishedAt = Date()
        XCTAssertEqual(sink.output, Data("3;ext=yes\r\nabc\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(transaction.requestBody, Data("abc".utf8))
        XCTAssertFalse(transaction.canCopyCurl); XCTAssertNil(transaction.curl())
    }
    func testCertificateSANPermissionsAndUntrustedTLSRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        try ca.prepare()
        let identity = try ca.identity(for: "localhost")
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        let leaf = try XCTUnwrap(certificate)
        let pem = try String(contentsOf: ca.certificateURL, encoding: .utf8)
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        func evaluate(_ host: String) -> Bool {
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
                  let trust else { return false }
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            return SecTrustEvaluateWithError(trust, nil)
        }
        XCTAssertTrue(evaluate("localhost")); XCTAssertFalse(evaluate("wrong.localhost"))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let keyPermissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("KriaCustomsCA.key").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(keyPermissions?.intValue, 0o600)
        let listener = try CustomsSocket.listen(port: 0, lan: false); defer { listener.cancel() }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try Self.accepted(listener); defer { socket.cancel() }
                let server = try CustomsTLSTransport(socket: socket, host: "localhost", identity: identity)
                try server.handshake()
            } catch { /* Expected peer rejection of an untrusted root. */ }
        }
        let socket = try CustomsSocket.connect(host: "127.0.0.1", port: listener.localPort, proxyPort: 0) { _ in }; defer { socket.cancel() }
        let client = try CustomsTLSTransport(socket: socket, host: "localhost")
        XCTAssertThrowsError(try client.handshake()) { error in
            XCTAssertTrue(error.localizedDescription.contains("证书"))
        }
        socket.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
}

#if CUSTOMS_STANDALONE_TEST
@main
nonisolated enum CustomsTestRunner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: CustomsProxyTests.self)
        suite.run()
        guard let result = suite.testRun else { exit(2) }
        print("Customs: \(result.executionCount) tests, \(result.totalFailureCount) failures")
        exit(result.hasSucceeded && result.executionCount >= 16 ? 0 : 1)
    }
}
#endif
