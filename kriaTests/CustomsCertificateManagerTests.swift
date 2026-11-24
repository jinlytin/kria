import Foundation
import Security
import Darwin
import XCTest
#if !CUSTOMS_CERTIFICATE_STANDALONE_TEST
@testable import kria
#endif

/// All mutation commands use FakeExecutor; only systemTrustStatus performs real (read-only) store access.
nonisolated final class CustomsCertificateManagerTests: XCTestCase {
    private final class FakeExecutor: CustomsCertificateCommandExecuting, @unchecked Sendable {
        struct Call { let executable: URL; let arguments: [String]; let timeout: TimeInterval; let certificate: Data? }
        let lock = NSLock()
        var calls: [Call] = []
        var failCommand: String?
        func execute(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CustomsCertificateCommandResult {
            lock.lock(); defer { lock.unlock() }
            let cert = arguments.first == "delete-certificate" ? nil : arguments.last.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            calls.append(.init(executable: executable, arguments: arguments, timeout: timeout, certificate: cert))
            return .init(exitCode: arguments.first == failCommand ? 1 : 0, standardError: Data("fake authorization denied".utf8))
        }
    }
    private static func status(user: Bool = false, admin: Bool = false, login: Bool = false, trusted: Bool = false) -> CustomsCertificateTrustStatus {
        .init(isTrusted: trusted, userTrusted: user, adminTrusted: admin, loginCertificatePresent: login)
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CustomsCertificateTests-\(UUID().uuidString)")
    }
    private func manager(_ ca: CustomsCertificateAuthority, _ fake: FakeExecutor,
                         status: CustomsCertificateTrustStatus = CustomsCertificateManagerTests.status()) -> CustomsCertificateManager {
        CustomsCertificateManager(authority: ca, executor: fake, trustInspector: { _, _ in status })
    }
    func testInspectMissingDoesNotGenerateAndIncompleteThrows() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        XCTAssertNil(try service.inspect())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: ca.certificateURL)
        XCTAssertThrowsError(try service.inspect())
        XCTAssertThrowsError(try service.prepare())
        XCTAssertEqual(try Data(contentsOf: ca.certificateURL), Data("damaged".utf8))
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testMetadataAndReadOnlyMacTrust() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        try ca.prepare()
        // No install/remove calls can reach a real runner in this test.
        let service = CustomsCertificateManager(authority: ca, executor: FakeExecutor())
        let info = try XCTUnwrap(service.inspect()), der = try ca.publicDER()
        XCTAssertTrue(info.subject.contains("Kria Customs Local CA"))
        XCTAssertFalse(info.serialNumber.isEmpty)
        XCTAssertEqual(info.sha256Fingerprint, CustomsCertificateManager.fingerprint(der))
        XCTAssertEqual(info.sha256Fingerprint.count, 64)
        XCTAssertLessThan(info.validFrom, info.validUntil)
        XCTAssertLessThan(abs(info.validFrom.timeIntervalSinceNow), 120)
        XCTAssertGreaterThan(info.validUntil.timeIntervalSinceNow, 3600 * 24 * 365 * 9)
        XCTAssertFalse(info.isTrusted); XCTAssertFalse(info.userTrusted); XCTAssertFalse(info.adminTrusted)
        XCTAssertEqual(info.certificatePath, ca.certificateURL.path)
    }
    func testExplicitSettingsAreNotEffectiveTrust() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = manager(CustomsCertificateAuthority(directory: directory), FakeExecutor(), status: Self.status(user: true, admin: true))
        let info = try service.prepare()
        XCTAssertTrue(info.userTrusted); XCTAssertTrue(info.adminTrusted); XCTAssertFalse(info.isTrusted)
    }
    func testInstallUsesOnlyUserSSLAndPublicSnapshot() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        _ = try service.installAndTrust()
        let call = try XCTUnwrap(fake.calls.first)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(call.executable.path, "/usr/bin/security")
        XCTAssertEqual(Array(call.arguments.prefix(7)), ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path])
        XCTAssertEqual(call.timeout, 120)
        XCTAssertFalse(call.arguments.contains("-d")); XCTAssertFalse(call.arguments.contains("-s")); XCTAssertFalse(call.arguments.contains("-e"))
        XCTAssertFalse(call.arguments.joined().contains("System.keychain")); XCTAssertFalse(call.arguments.contains { $0.hasSuffix(".key") })
        XCTAssertEqual(call.certificate, try ca.publicDER())
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(call.arguments.last)))
    }
    func testRemoveUsesExactSHA256AndOnlyLoginKeychain() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let service = manager(ca, fake, status: Self.status(user: true, admin: true, login: true))
        let before = try service.prepare()
        _ = try service.removeUserTrust()
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(fake.calls[0].arguments.first, "remove-trusted-cert")
        XCTAssertEqual(fake.calls[0].arguments.count, 2)
        XCTAssertEqual(fake.calls[0].certificate, try ca.publicDER())
        XCTAssertEqual(fake.calls[1].arguments, ["delete-certificate", "-Z", before.sha256Fingerprint,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path])
        XCTAssertFalse(fake.calls.flatMap(\.arguments).contains("-c"))
        XCTAssertFalse(fake.calls.flatMap(\.arguments).contains("-d"))
        XCTAssertFalse(fake.calls.flatMap(\.arguments).contains("-t"))
        XCTAssertEqual(try service.inspect()?.sha256Fingerprint, before.sha256Fingerprint)
    }
    func testRemoveMissingAndAlreadyAbsentAreNoOps() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeExecutor(), service = manager(CustomsCertificateAuthority(directory: directory), fake)
        XCTAssertNil(try service.removeUserTrust())
        _ = try service.prepare(); XCTAssertNotNil(try service.removeUserTrust())
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testResetRefusesAdminSettingsAndPreservesPair() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let service = manager(ca, fake, status: Self.status(admin: true))
        let before = try service.prepare(), key = directory.appendingPathComponent("KriaCustomsCA.key")
        let keyData = try Data(contentsOf: key)
        XCTAssertThrowsError(try service.reset()) { XCTAssertTrue($0.localizedDescription.contains("管理员")) }
        XCTAssertEqual(try service.inspect()?.sha256Fingerprint, before.sha256Fingerprint)
        XCTAssertEqual(try Data(contentsOf: key), keyData)
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testResetRotatesAndPreservesUnmanagedFilesWithoutOldKeys() throws {
        let parent = temporaryDirectory(), directory = parent.appendingPathComponent("CA")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let service = manager(ca, fake, status: Self.status(user: true, login: true))
        let before = try service.prepare(), oldDER = try ca.publicDER()
        let other = directory.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: other)
        let after = try service.reset()
        XCTAssertNotEqual(before.sha256Fingerprint, after.sha256Fingerprint)
        XCTAssertEqual(fake.calls[0].certificate, oldDER)
        XCTAssertEqual(fake.calls[1].arguments[2], before.sha256Fingerprint)
        XCTAssertEqual(try Data(contentsOf: other), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["CA"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("KriaCustomsCA.key").path)[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }
    func testResetFailureKeepsOriginalAndReportsPartialTrustRemoval() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        fake.failCommand = "delete-certificate"
        let service = manager(ca, fake, status: Self.status(user: true, login: true))
        let before = try service.prepare()
        XCTAssertThrowsError(try service.reset()) { XCTAssertTrue($0.localizedDescription.contains("部分移除")) }
        XCTAssertEqual(try service.inspect()?.sha256Fingerprint, before.sha256Fingerprint)
        try ca.prepare()
    }
    func testRotationCallbackFailureDoesNotReplaceCA() throws {
        let parent = temporaryDirectory(), directory = parent.appendingPathComponent("CA")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ca = CustomsCertificateAuthority(directory: directory)
        try ca.prepare(); let before = try ca.publicDER()
        XCTAssertThrowsError(try ca.rotate { _ in throw CustomsBackendError.message("fake precommit failure") })
        XCTAssertEqual(try ca.publicDER(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["CA"])
    }
    func testCorruptAndMissingKeyResetDoesNotGuessSubject() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        _ = try service.prepare()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("KriaCustomsCA.key"))
        XCTAssertThrowsError(try service.inspect())
        XCTAssertNotNil(try service.reset())
        try Data("corrupt".utf8).write(to: ca.certificateURL)
        XCTAssertThrowsError(try service.inspect())
        XCTAssertNotNil(try service.reset())
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testPublicExportRejectsBundleAndPrivateMaterial() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        try ca.prepare()
        let pem = try Data(contentsOf: ca.certificateURL), der = try ca.publicDER()
        try (pem + pem).write(to: ca.certificateURL)
        XCTAssertThrowsError(try ca.publicDER())
        try (der + der).write(to: ca.certificateURL)
        XCTAssertThrowsError(try ca.publicDER())
        let key = try Data(contentsOf: directory.appendingPathComponent("KriaCustomsCA.key"))
        try (pem + key).write(to: ca.certificateURL)
        XCTAssertThrowsError(try ca.publicDER())
    }
    func testSymlinkRootOrManagedFileIsRejectedWithoutTouchingTarget() throws {
        let parent = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("real"), link = parent.appendingPathComponent("link")
        let ca = CustomsCertificateAuthority(directory: target)
        try ca.prepare(); let before = try ca.publicDER()
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let unsafe = CustomsCertificateAuthority(directory: link)
        XCTAssertThrowsError(try unsafe.prepare()); XCTAssertThrowsError(try unsafe.rotate())
        XCTAssertEqual(try ca.publicDER(), before)
        let key = target.appendingPathComponent("KriaCustomsCA.key"), saved = parent.appendingPathComponent("saved.key")
        try FileManager.default.moveItem(at: key, to: saved)
        try FileManager.default.createSymbolicLink(at: key, withDestinationURL: saved)
        XCTAssertThrowsError(try ca.publicDER()); XCTAssertThrowsError(try ca.rotate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }
    func testDeletedPairRegeneratesAndRotationClearsLeafCache() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory)
        let oldIdentity = try ca.identity(for: "localhost"), before = try ca.publicDER()
        try FileManager.default.removeItem(at: ca.certificateURL)
        XCTAssertThrowsError(try ca.identity(for: "localhost"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("KriaCustomsCA.key"))
        let regenerated = try ca.identity(for: "localhost")
        XCTAssertNotEqual(try ca.publicDER(), before)
        XCTAssertFalse(CFEqual(oldIdentity, regenerated))
        _ = try ca.rotate()
        XCTAssertFalse(CFEqual(regenerated, try ca.identity(for: "localhost")))
    }
    func testExpiredCertificateRemainsInspectableAndInstallDoesNotBypassExpiry() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        _ = try service.prepare()
        let expired = directory.appendingPathComponent("expired.crt")
        let config = directory.appendingPathComponent("expiry.cnf"), csr = directory.appendingPathComponent("expiry.csr")
        let database = directory.appendingPathComponent("index"), serial = directory.appendingPathComponent("serial")
        try Data().write(to: database); try Data("01\n".utf8).write(to: serial)
        try Data("""
        [ca]
        default_ca=local
        [local]
        database=\(database.path)
        serial=\(serial.path)
        new_certs_dir=\(directory.path)
        default_md=sha256
        policy=simple
        [simple]
        commonName=supplied
        [root]
        basicConstraints=critical,CA:TRUE
        keyUsage=critical,keyCertSign,cRLSign
        """.utf8).write(to: config)
        let executor = CustomsCertificateProcessExecutor(), openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        let key = directory.appendingPathComponent("KriaCustomsCA.key")
        let request = try executor.execute(executable: openssl,
            arguments: ["req", "-new", "-key", key.path, "-subj", "/CN=Kria Customs Local CA", "-out", csr.path], timeout: 20)
        XCTAssertEqual(request.exitCode, 0)
        let result = try executor.execute(executable: openssl,
            arguments: ["ca", "-selfsign", "-batch", "-notext", "-config", config.path, "-keyfile", key.path,
                        "-in", csr.path, "-out", expired.path, "-startdate", "20000101000000Z", "-enddate", "20010101000000Z", "-extensions", "root"], timeout: 20)
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.standardError, as: UTF8.self))
        try Data(contentsOf: expired).write(to: ca.certificateURL)
        let info = try XCTUnwrap(service.inspect())
        XCTAssertTrue(info.isExpired)
        XCTAssertLessThan(info.validUntil, Date())
        XCTAssertThrowsError(try service.installAndTrust())
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testIncompletePairStillBlocksAdminResetForReadableOldCertificate() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let service = manager(ca, fake, status: Self.status(admin: true))
        _ = try service.prepare(); let original = try Data(contentsOf: ca.certificateURL)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("KriaCustomsCA.key"))
        XCTAssertThrowsError(try service.reset()) { XCTAssertTrue($0.localizedDescription.contains("管理员")) }
        XCTAssertEqual(try Data(contentsOf: ca.certificateURL), original)
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testConcurrentManagersShareAuthorityTransactionLock() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let first = manager(ca, fake), second = manager(ca, fake)
        _ = try first.prepare()
        let group = DispatchGroup()
        for index in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    if index.isMultiple(of: 2) { _ = try first.reset() }
                    else { XCTAssertNotNil(try second.inspect()) }
                } catch { XCTFail("并发 CA 管理失败：\(error)") }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertNotNil(try second.inspect()); XCTAssertTrue(fake.calls.isEmpty)
    }
    private func verifyRemovalWithInvalidKey(_ damage: String) throws {
        let parent = temporaryDirectory(), directory = parent.appendingPathComponent("CA")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let service = manager(ca, fake, status: Self.status(user: true, login: true))
        let confirmed = try service.prepare(), der = try ca.publicDER()
        let key = directory.appendingPathComponent("KriaCustomsCA.key")
        switch damage {
        case "missing": try FileManager.default.removeItem(at: key)
        case "garbage": try Data("not a private key".utf8).write(to: key)
        default:
            let other = CustomsCertificateAuthority(directory: parent.appendingPathComponent("other"))
            try other.prepare()
            try Data(contentsOf: other.certificateURL.deletingLastPathComponent().appendingPathComponent("KriaCustomsCA.key")).write(to: key)
        }
        XCTAssertThrowsError(try service.inspect())
        XCTAssertEqual(try ca.existingCertificateDER(), der)
        let result = try XCTUnwrap(service.removeUserTrust(expectedFingerprint: confirmed.sha256Fingerprint))
        XCTAssertEqual(result.sha256Fingerprint, confirmed.sha256Fingerprint)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(fake.calls[0].arguments.first, "remove-trusted-cert")
        XCTAssertEqual(fake.calls[0].certificate, der)
        XCTAssertEqual(fake.calls[1].arguments, ["delete-certificate", "-Z", confirmed.sha256Fingerprint,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path])
        XCTAssertThrowsError(try service.inspect(), "撤销不能修复或生成私钥")
    }
    func testRemoveWithMissingPrivateKey() throws { try verifyRemovalWithInvalidKey("missing") }
    func testRemoveWithGarbagePrivateKey() throws { try verifyRemovalWithInvalidKey("garbage") }
    func testRemoveWithMismatchedPrivateKey() throws { try verifyRemovalWithInvalidKey("mismatch") }

    private func verifyFIFORejected(_ name: String) throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        _ = try service.prepare()
        let fifo = ca.certificateURL.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.removeItem(at: fifo)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let operations: [@Sendable () throws -> Void] = [
            { _ = try service.inspect() }, { try ca.prepare() }, { _ = try service.reset() }
        ]
        for operation in operations {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    try operation()
                    XCTFail("FIFO 操作必须拒绝非普通文件")
                } catch { /* Expected: rejected before any blocking read or trust mutation. */ }
            }
            let finished = done.wait(timeout: .now() + 2)
            XCTAssertEqual(finished, .success, "FIFO 必须快速抛错，不能等待写入端")
            if finished != .success {
                // Release a regressed blocking open so the test itself need not permanently hang.
                let writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                if writer >= 0 { Darwin.close(writer) }
                _ = done.wait(timeout: .now() + 25)
                return
            }
        }
        XCTAssertTrue(fake.calls.isEmpty)
        if name.hasSuffix(".key") {
            // Public-only revocation must not even open this FIFO key.
            XCTAssertNotNil(try ca.existingCertificateDER())
            XCTAssertNotNil(try service.removeUserTrust())
        } else { XCTAssertThrowsError(try ca.existingCertificateDER()) }
    }
    func testCertificateFIFOReadPrepareResetRejectPromptly() throws { try verifyFIFORejected("KriaCustomsCA.crt") }
    func testPrivateKeyFIFOInspectPrepareResetRejectPromptly() throws { try verifyFIFORejected("KriaCustomsCA.key") }

    func testWrongExpectedFingerprintRejectsAllMutationsWithoutRotation() throws {
        let parent = temporaryDirectory(), directory = parent.appendingPathComponent("CA")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let service = manager(ca, fake, status: Self.status(user: true, login: true))
        let original = try service.prepare(), key = directory.appendingPathComponent("KriaCustomsCA.key")
        let oldKey = try Data(contentsOf: key)
        let wrong = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try service.installAndTrust(expectedFingerprint: wrong))
        XCTAssertThrowsError(try service.removeUserTrust(expectedFingerprint: wrong))
        XCTAssertThrowsError(try service.reset(expectedFingerprint: wrong))
        XCTAssertEqual(try service.inspect()?.sha256Fingerprint, original.sha256Fingerprint)
        XCTAssertEqual(try Data(contentsOf: key), oldKey)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["CA"])
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testExpectedFingerprintMissingCertificateNeverAutoGenerates() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        let expected = String(repeating: "1", count: 64)
        XCTAssertThrowsError(try service.installAndTrust(expectedFingerprint: expected))
        XCTAssertThrowsError(try service.removeUserTrust(expectedFingerprint: expected))
        XCTAssertThrowsError(try service.reset(expectedFingerprint: expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ca.certificateURL.deletingLastPathComponent().path))
        let original = try service.prepare()
        try FileManager.default.removeItem(at: ca.certificateURL)
        try FileManager.default.removeItem(at: ca.certificateURL.deletingLastPathComponent().appendingPathComponent("KriaCustomsCA.key"))
        XCTAssertThrowsError(try service.installAndTrust(expectedFingerprint: original.sha256Fingerprint))
        XCTAssertNil(try ca.existingCertificateDER())
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testExternallyReplacedPairRejectsConfirmedOldFingerprint() throws {
        let parent = temporaryDirectory(), directory = parent.appendingPathComponent("CA")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        let original = try service.prepare()
        let replacement = CustomsCertificateAuthority(directory: parent.appendingPathComponent("replacement"))
        try replacement.prepare()
        try Data(contentsOf: replacement.certificateURL).write(to: ca.certificateURL)
        let keyName = "KriaCustomsCA.key"
        try Data(contentsOf: replacement.certificateURL.deletingLastPathComponent().appendingPathComponent(keyName))
            .write(to: ca.certificateURL.deletingLastPathComponent().appendingPathComponent(keyName))
        let newDER = try replacement.publicDER()
        XCTAssertThrowsError(try service.installAndTrust(expectedFingerprint: original.sha256Fingerprint))
        XCTAssertThrowsError(try service.removeUserTrust(expectedFingerprint: original.sha256Fingerprint))
        XCTAssertThrowsError(try service.reset(expectedFingerprint: original.sha256Fingerprint))
        XCTAssertEqual(try ca.publicDER(), newDER)
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testMatchingFingerprintAllowsInstallRemoveAndReset() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor()
        let service = manager(ca, fake, status: Self.status(user: true, login: true))
        let original = try service.prepare(), fingerprint = original.sha256Fingerprint
        XCTAssertEqual(try service.installAndTrust(expectedFingerprint: fingerprint).sha256Fingerprint, fingerprint)
        XCTAssertEqual(try service.removeUserTrust(expectedFingerprint: fingerprint)?.sha256Fingerprint, fingerprint)
        let replacement = try service.reset(expectedFingerprint: fingerprint)
        XCTAssertNotEqual(replacement.sha256Fingerprint, fingerprint)
        XCTAssertEqual(fake.calls.count, 5)
        XCTAssertEqual(try service.inspect()?.sha256Fingerprint, replacement.sha256Fingerprint)
    }
    func testPublicOnlyReadMissingCertificateIgnoresOrphanKey() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ca = CustomsCertificateAuthority(directory: directory), fake = FakeExecutor(), service = manager(ca, fake)
        _ = try service.prepare()
        try FileManager.default.removeItem(at: ca.certificateURL)
        XCTAssertNil(try ca.existingCertificateDER())
        XCTAssertNil(try service.removeUserTrust())
        XCTAssertThrowsError(try service.inspect())
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testProcessDrainsBoundedOutputAndTimesOutWithoutTrustMutation() throws {
        let executor = CustomsCertificateProcessExecutor()
        let result = try executor.execute(executable: URL(fileURLWithPath: "/usr/bin/seq"), arguments: ["1", "100000"], timeout: 10)
        XCTAssertEqual(result.exitCode, 0); XCTAssertEqual(result.standardOutput.count, 64 * 1024)
        XCTAssertThrowsError(try executor.execute(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1))
    }
}

#if CUSTOMS_CERTIFICATE_STANDALONE_TEST
@main
nonisolated enum CustomsCertificateTestRunner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: CustomsCertificateManagerTests.self)
        suite.run()
        guard let result = suite.testRun else { exit(2) }
        print("Customs certificates: \(result.executionCount) tests, \(result.totalFailureCount) failures")
        exit(result.hasSucceeded && result.executionCount >= 28 ? 0 : 1)
    }
}
#endif
