import Foundation
import Darwin
import CryptoKit
import Security
import XCTest
#if !CUSTOMS_CERTIFICATE_DOWNLOAD_STANDALONE_TEST
@testable import kria
#endif

nonisolated final class CustomsCertificateDownloadTests: XCTestCase {
    private static let fixture: Result<Data, Error> = Result {
        // Keep the disposable fixture under the user directory: macOS standardizes
        // /private/var temporary URLs back to /var, which CA correctly rejects as a symlink.
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".customs-download-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        try ca.prepare()
        let der = try ca.publicDER()
        XCTAssertNotNil(SecCertificateCreateWithData(nil, der as CFData))
        return der
    }
    private func certificate() throws -> Data { try Self.fixture.get() }
    private func start(_ server: CustomsCertificateDownloadServer, duration: TimeInterval = 600,
                       fingerprint: String = "caller-text") throws -> CustomsCertificateDownloadSession {
        try server.start(certificateDER: certificate(), fingerprint: fingerprint, listenOnLAN: false, duration: duration)
    }
    /// Numeric loopback only: no resolver, proxy or external network.
    private static func connect(_ port: UInt16) throws -> CustomsSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CustomsBackendError.system("测试 socket") }
        let socket = try CustomsSocket(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw CustomsBackendError.system("测试连接") }
            try socket.wait(Int16(POLLOUT), deadline: Date().addingTimeInterval(2))
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw CustomsBackendError.message("测试端口已关闭")
            }
        }
        return socket
    }
    private struct Response {
        let head: CustomsHTTP.Head
        let body: Data
    }
    private static func receive(_ socket: CustomsSocket) throws -> Response {
        // Never let a broken close/HEAD implementation hang the test for 30 seconds.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak socket] in socket?.cancel() }
        timer.resume(); defer { timer.cancel() }
        let reader = CustomsHTTPReader(CustomsPlainTransport(socket))
        let head = try reader.head()
        var body = Data()
        while true {
            let data = try reader.block(maximum: 4096)
            if data.isEmpty { break }
            body.append(data)
            guard body.count <= 1024 * 1024 else { throw CustomsBackendError.message("测试响应过大") }
        }
        return Response(head: head, body: body)
    }
    private static func request(_ session: CustomsCertificateDownloadSession, path: String,
                                method: String = "GET", headers: String = "") throws -> Response {
        let socket = try connect(session.port); defer { socket.cancel() }
        try CustomsPlainTransport(socket).write(Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(headers)\r\n".utf8))
        return try receive(socket)
    }
    private static func eventually(_ predicate: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return predicate()
    }
    private static func portClosed(_ port: UInt16) -> Bool {
        do { let socket = try connect(port); socket.cancel(); return false } catch { return true }
    }

    private static func closedConnection(_ socket: CustomsSocket) throws -> Bool {
        try socket.wait(Int16(POLLIN), deadline: Date().addingTimeInterval(2))
        do { return try CustomsPlainTransport(socket).read(maximum: 1).isEmpty }
        catch {
            // An unread connection in the accept backlog is legitimately reset on stop.
            if error.localizedDescription.contains(String(cString: strerror(ECONNRESET))) { return true }
            throw error
        }
    }

    func testManualStartDefaultSessionAndExactBinaryDownload() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        XCTAssertFalse(server.isRunning)
        let before = Date(), session = try start(server)
        XCTAssertTrue(server.isRunning); XCTAssertGreaterThan(session.port, 0)
        XCTAssertEqual(session.addresses, ["127.0.0.1"])
        XCTAssertEqual(session.urls, ["http://127.0.0.1:\(session.port)/\(session.token)/"])
        XCTAssertNotNil(UUID(uuidString: session.token))
        XCTAssertEqual(session.expiresAt.timeIntervalSince(before), 600, accuracy: 1)
        let der = try certificate()
        XCTAssertEqual(session.fingerprint, SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined())
        let response = try Self.request(session, path: "/\(session.token)/KriaCustomsCA.cer")
        XCTAssertEqual(response.head.status, 200); XCTAssertEqual(response.body, der)
        XCTAssertEqual(response.head.values("content-type"), ["application/x-x509-ca-cert"])
        XCTAssertEqual(response.head.values("content-disposition"), ["attachment; filename=\"KriaCustomsCA.cer\""])
        XCTAssertEqual(response.head.values("content-length"), [String(der.count)])
        XCTAssertEqual(response.head.values("cache-control"), ["no-store"])
        XCTAssertEqual(response.head.values("x-content-type-options"), ["nosniff"])
        XCTAssertEqual(response.head.values("connection"), ["close"])
    }
    func testInstallationHTMLDoesNotEmbedCallerText() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        let session = try start(server, fingerprint: "<script>alert('private-user-data')</script>")
        let response = try Self.request(session, path: "/\(session.token)/")
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertEqual(response.head.status, 200)
        XCTAssertTrue(html.contains("默认 8888")); XCTAssertTrue(html.contains("必须在海关允许代理 LAN"))
        XCTAssertTrue(html.contains(try XCTUnwrap(session.fingerprint)))
        XCTAssertTrue(html.contains("/\(session.token)/KriaCustomsCA.cer"))
        XCTAssertFalse(html.contains("<script")); XCTAssertFalse(html.contains("private-user-data"))
        XCTAssertFalse(html.contains("BEGIN PRIVATE KEY"))
    }
    func testExactRoutesAndMethods() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        let session = try start(server), prefix = "/\(session.token)/"
        for path in ["/", "/wrong/", prefix + "../KriaCustomsCA.cer", prefix + "%2e%2e/KriaCustomsCA.cer",
                     prefix + "KriaCustomsCA.key", prefix + "settings", prefix + "?q=1",
                     prefix + "KriaCustomsCA.cer?q=1", prefix + "KriaCustomsCA.cer/", "http://127.0.0.1" + prefix] {
            XCTAssertEqual(try Self.request(session, path: path).head.status, 404, path)
        }
        for method in ["POST", "CONNECT", "PUT", "OPTIONS", "DELETE", "get"] {
            let response = try Self.request(session, path: prefix, method: method)
            XCTAssertEqual(response.head.status, 405, method)
            XCTAssertEqual(response.head.values("allow"), ["GET, HEAD"])
            XCTAssertTrue(response.body.isEmpty)
        }
    }
    func testHEADHasGETLengthButNoBody() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        let session = try start(server)
        for path in ["/\(session.token)/", "/\(session.token)/KriaCustomsCA.cer", "/"] {
            let get = try Self.request(session, path: path)
            let head = try Self.request(session, path: path, method: "HEAD")
            XCTAssertEqual(head.head.status, get.head.status)
            XCTAssertEqual(head.head.values("content-length"), get.head.values("content-length"))
            XCTAssertTrue(head.body.isEmpty)
        }
    }
    func testFragmentedHeadersAndEightKiBBoundary() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        let session = try start(server)
        let socket = try Self.connect(session.port); defer { socket.cancel() }
        let transport = CustomsPlainTransport(socket)
        for fragment in ["GET /\(session.token)/KriaCustomsCA.cer HTTP/1.1\r", "\nHost: local\r\n", "\r", "\n"] {
            try transport.write(Data(fragment.utf8))
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(try Self.receive(socket).body, try certificate())
        let base = "GET /\(session.token)/ HTTP/1.1\r\nHost: local\r\nX-Pad: "
        let exact = base + String(repeating: "a", count: 8192 - base.utf8.count - 4) + "\r\n\r\n"
        let boundary = try Self.connect(session.port); defer { boundary.cancel() }
        try CustomsPlainTransport(boundary).write(Data(exact.utf8))
        XCTAssertEqual(try Self.receive(boundary).head.status, 200)
        let oversized = try Self.connect(session.port); defer { oversized.cancel() }
        // No terminator: rejection must happen before the complete head arrives.
        try CustomsPlainTransport(oversized).write(Data((base + String(repeating: "b", count: 8192 - base.utf8.count)).utf8))
        XCTAssertEqual(try Self.receive(oversized).head.status, 431)
    }
    func testInvalidCertificatesAndParametersDoNotStart() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        for data in [Data(), Data("-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----".utf8),
                     Data("-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----".utf8), Data([1, 2, 3])] {
            XCTAssertThrowsError(try server.start(certificateDER: data, fingerprint: "", listenOnLAN: false))
            XCTAssertFalse(server.isRunning)
        }
        let der = try certificate()
        for extra in [Data([0]), der, Data("-----BEGIN PRIVATE KEY-----".utf8)] {
            XCTAssertThrowsError(try server.start(certificateDER: der + extra, fingerprint: "", listenOnLAN: false))
        }
        XCTAssertThrowsError(try start(server, fingerprint: String(repeating: "x", count: 257)))
        for duration in [0.0, -1, .nan, .infinity, 86401] {
            XCTAssertThrowsError(try start(server, duration: duration))
        }
        XCTAssertFalse(server.isRunning)
    }
    func testNoLANAndAddressProviderRefreshWithoutLANListener() throws {
        final class Addresses: @unchecked Sendable {
            let lock = NSLock(); var reads = 0
            func next() -> [String] {
                lock.lock(); defer { lock.unlock() }; reads += 1
                return reads == 1 ? [] : ["127.0.0.1", "not-an-ip", "0.0.0.0"]
            }
        }
        let addresses = Addresses()
        let server = CustomsCertificateDownloadServer(localAddressProvider: { addresses.next() })
        defer { server.stop() }
        for _ in 0..<2 {
            XCTAssertThrowsError(try server.start(certificateDER: certificate(), fingerprint: "")) {
                XCTAssertTrue($0.localizedDescription.contains("没有已启用的非回环 IPv4"))
            }
        }
        XCTAssertEqual(addresses.reads, 2); XCTAssertFalse(server.isRunning)
        let session = try start(server)
        XCTAssertEqual(session.addresses, ["127.0.0.1"]); XCTAssertEqual(addresses.reads, 2)
    }
    func testExpiryCancelsPartialRequestAndClosesPort() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        let session = try start(server, duration: 0.15)
        let partial = try Self.connect(session.port); defer { partial.cancel() }
        try CustomsPlainTransport(partial).write(Data("GET /\(session.token)/ HTTP/1.1\r\n".utf8))
        XCTAssertTrue(Self.eventually { !server.isRunning && Self.portClosed(session.port) })
        XCTAssertTrue(try Self.closedConnection(partial))
    }
    func testStopRestartIsolatesOldTimerClientsAndToken() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        let old = try start(server, duration: 0.2)
        let partial = try Self.connect(old.port); defer { partial.cancel() }
        try CustomsPlainTransport(partial).write(Data("GET / HTTP/1.1\r\n".utf8))
        server.stop(); server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertTrue(Self.eventually { Self.portClosed(old.port) })
        let next = try start(server, duration: 3)
        XCTAssertNotEqual(old.token, next.token)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(server.isRunning)
        XCTAssertEqual(try Self.request(next, path: "/\(old.token)/").head.status, 404)
        XCTAssertEqual(try Self.request(next, path: "/\(next.token)/KriaCustomsCA.cer").body, try certificate())
        XCTAssertTrue(try Self.closedConnection(partial))
        // Failed replacement does not invalidate a valid session.
        XCTAssertThrowsError(try server.start(certificateDER: Data(), fingerprint: "", listenOnLAN: false))
        XCTAssertTrue(server.isRunning)
    }
    func testEightConcurrentDownloadsAndOverloadCancellation() throws {
        let server = CustomsCertificateDownloadServer(); defer { server.stop() }
        let session = try start(server), der = try certificate()
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                do {
                    let response = try Self.request(session, path: "/\(session.token)/KriaCustomsCA.cer")
                    XCTAssertEqual(response.head.status, 200); XCTAssertEqual(response.body, der)
                } catch { XCTFail("并发下载失败: \(error)") }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        var clients: [CustomsSocket] = []
        defer { clients.forEach { $0.cancel() } }
        for _ in 0..<8 {
            let socket = try Self.connect(session.port); clients.append(socket)
            try CustomsPlainTransport(socket).write(Data("GET / HTTP/1.1\r\n".utf8))
        }
        // A barrier probe is ordered after the eight connections in the accept backlog.
        let overflow = try Self.connect(session.port); defer { overflow.cancel() }
        XCTAssertTrue(try Self.closedConnection(overflow))
        let before = Date(); server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.5)
        XCTAssertTrue(Self.eventually { Self.portClosed(session.port) })
        for client in clients { XCTAssertTrue(try Self.closedConnection(client)) }
        let restarted = try start(server)
        XCTAssertTrue(Self.eventually {
            (try? Self.request(restarted, path: "/\(restarted.token)/KriaCustomsCA.cer").head.status) == 200
        })
    }
    func testDeinitializationClosesListener() throws {
        var server: CustomsCertificateDownloadServer? = CustomsCertificateDownloadServer()
        weak let weakServer = server
        let session = try start(try XCTUnwrap(server))
        server = nil
        XCTAssertTrue(Self.eventually { weakServer == nil && Self.portClosed(session.port) })
    }
}

#if CUSTOMS_CERTIFICATE_DOWNLOAD_STANDALONE_TEST
@main
nonisolated enum CustomsCertificateDownloadTestRunner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: CustomsCertificateDownloadTests.self)
        suite.run()
        guard let run = suite.testRun else { exit(2) }
        print("Certificate download: \(run.executionCount) tests, \(run.totalFailureCount) failures")
        exit(run.hasSucceeded && run.executionCount >= 11 ? 0 : 1)
    }
}
#endif
