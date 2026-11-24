import Darwin
import Foundation
import XCTest
@testable import kria

/// Disposable CA files only; every trust-store mutation is intercepted by the fake executor.
nonisolated final class CustomsCertificateViewModelTests: XCTestCase {
    nonisolated private final class FakeCommandExecutor: CustomsCertificateCommandExecuting, @unchecked Sendable {
        struct Call: Sendable {
            let executable: URL
            let arguments: [String]
            let certificate: Data?
        }

        private let lock = NSLock()
        private var recordedCalls: [Call] = []

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return recordedCalls
        }

        func execute(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CustomsCertificateCommandResult {
            let certificate = arguments.first == "delete-certificate" ? nil : arguments.last.flatMap {
                try? Data(contentsOf: URL(fileURLWithPath: $0))
            }
            lock.lock(); defer { lock.unlock() }
            recordedCalls.append(.init(executable: executable, arguments: arguments, certificate: certificate))
            return .init(exitCode: 0)
        }
    }

    nonisolated private final class FakeTrustInspector: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedReads = 0
        private let status: CustomsCertificateTrustStatus

        init(userTrustPresent: Bool) {
            // Even the removal fixture reports no effective SSL trust and no administrator settings.
            status = .init(isTrusted: false, userTrusted: userTrustPresent,
                           adminTrusted: false, loginCertificatePresent: userTrustPresent)
        }

        var reads: Int {
            lock.lock(); defer { lock.unlock() }
            return recordedReads
        }

        func inspect() -> CustomsCertificateTrustStatus {
            lock.lock(); defer { lock.unlock() }
            recordedReads += 1
            return status
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let authority: CustomsCertificateAuthority
        let executor: FakeCommandExecutor
        let inspector: FakeTrustInspector
        let server: CustomsCertificateDownloadServer
        let vm: CustomsViewModel

        var keyURL: URL { authority.certificateURL.deletingLastPathComponent().appendingPathComponent("KriaCustomsCA.key") }

        init(userTrustPresent: Bool = false) {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("CustomsCertificateVMTests-\(UUID().uuidString)", isDirectory: true)
            let authority = CustomsCertificateAuthority(directory: root.appendingPathComponent("CA", isDirectory: true))
            let executor = FakeCommandExecutor()
            let inspector = FakeTrustInspector(userTrustPresent: userTrustPresent)
            let manager = CustomsCertificateManager(authority: authority, executor: executor,
                                                    trustInspector: { _, _ in inspector.inspect() })
            let server = CustomsCertificateDownloadServer(localAddressProvider: { [] })
            self.root = root
            self.authority = authority
            self.executor = executor
            self.inspector = inspector
            self.server = server
            // Settings must be outside the atomically rotated CA directory, never the real app settings.
            vm = CustomsViewModel(storageURL: root.appendingPathComponent("settings.json"),
                                  certificateManager: manager, certificateDownloadServer: server)
        }

        func cleanup() async throws {
            await vm.certificateTask?.value
            vm.shutdown()
            server.stop()
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    @MainActor private func withFixture(userTrustPresent: Bool = false,
                                       _ body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = Fixture(userTrustPresent: userTrustPresent)
        do {
            try await body(fixture)
        } catch {
            try await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }

    @MainActor private func prepare(_ fixture: Fixture) async throws -> CustomsCertificateInfo {
        fixture.vm.prepareCertificate()
        let task = try XCTUnwrap(fixture.vm.certificateTask)
        await task.value
        XCTAssertFalse(fixture.vm.certificateBusy)
        XCTAssertNil(fixture.vm.certificateError)
        return try XCTUnwrap(fixture.vm.certificateInfo)
    }

    @MainActor private func unusedLoopbackPort() throws -> UInt16 {
        let probe = try CustomsSocket.listen(port: 0, lan: false)
        defer { probe.cancel() }
        let port = probe.localPort
        XCTAssertGreaterThanOrEqual(port, 1024)
        return port // The descriptor is released before the VM binds this port.
    }

    @MainActor private func waitForProxyStart(_ vm: CustomsViewModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !vm.isRunning && vm.isStarting && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(vm.isStarting, "代理启动必须在 5 秒内完成")
        XCTAssertTrue(vm.isRunning, vm.message ?? "代理未启动")
        guard vm.isRunning else { throw CustomsBackendError.message("测试代理启动失败") }
    }

    @MainActor func testFreshRefreshAndUnconfirmedInstallNeverGenerateCA() async throws {
        try await withFixture { fixture in
            let vm = fixture.vm
            XCTAssertNil(vm.certificateInfo)
            XCTAssertFalse(vm.certificateBusy)
            vm.refreshCertificateStatus()
            XCTAssertTrue(vm.certificateBusy)
            await vm.certificateTask?.value
            XCTAssertFalse(vm.certificateBusy)
            XCTAssertNil(vm.certificateInfo)
            XCTAssertNil(vm.certificateError)
            let readTask = vm.certificateTask
            vm.installCertificate()
            XCTAssertNotNil(vm.certificateError)
            XCTAssertEqual(vm.certificateTask, readTask)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.authority.certificateURL.deletingLastPathComponent().path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.keyURL.path))
            XCTAssertEqual(fixture.inspector.reads, 0)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testPreparePublishesUntrustedMetadataWithoutTrustCommands() async throws {
        try await withFixture { fixture in
            let info = try await prepare(fixture)
            XCTAssertTrue(info.subject.contains("Kria Customs Local CA"))
            XCTAssertFalse(info.serialNumber.isEmpty)
            XCTAssertEqual(info.sha256Fingerprint, CustomsCertificateManager.fingerprint(try fixture.authority.publicDER()))
            XCTAssertEqual(info.sha256Fingerprint.count, 64)
            XCTAssertLessThan(info.validFrom, info.validUntil)
            XCTAssertFalse(info.isExpired)
            XCTAssertFalse(info.isTrusted)
            XCTAssertFalse(info.userTrusted)
            XCTAssertFalse(info.adminTrusted)
            XCTAssertEqual(info.certificatePath, fixture.authority.certificateURL.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.keyURL.path))
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testDamagedCertificateRefreshAndPrepareKeepKeyAndReportError() async throws {
        try await withFixture { fixture in
            let original = try await prepare(fixture)
            let key = try Data(contentsOf: fixture.keyURL)
            let damaged = Data("not a certificate".utf8)
            try damaged.write(to: fixture.authority.certificateURL)
            fixture.vm.refreshCertificateStatus()
            await fixture.vm.certificateTask?.value
            XCTAssertNotNil(fixture.vm.certificateError)
            XCTAssertFalse(fixture.vm.certificateBusy)
            // Failure deliberately retains the previously displayed metadata.
            XCTAssertEqual(fixture.vm.certificateInfo?.sha256Fingerprint, original.sha256Fingerprint)
            fixture.vm.prepareCertificate()
            await fixture.vm.certificateTask?.value
            XCTAssertNotNil(fixture.vm.certificateError)
            XCTAssertEqual(try Data(contentsOf: fixture.keyURL), key)
            XCTAssertEqual(try Data(contentsOf: fixture.authority.certificateURL), damaged)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testResetRecoversDamagedUnconfirmedCertificate() async throws {
        try await withFixture { fixture in
            // Generate only this disposable pair without publishing a confirmed fingerprint to the VM.
            try fixture.authority.prepare()
            let oldKey = try Data(contentsOf: fixture.keyURL)
            try Data("damaged".utf8).write(to: fixture.authority.certificateURL)
            fixture.vm.refreshCertificateStatus()
            await fixture.vm.certificateTask?.value
            XCTAssertNotNil(fixture.vm.certificateError)
            XCTAssertNil(fixture.vm.certificateInfo)
            fixture.vm.resetCertificate()
            await fixture.vm.certificateTask?.value
            let recovered = try XCTUnwrap(fixture.vm.certificateInfo)
            XCTAssertNil(fixture.vm.certificateError)
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertEqual(recovered.sha256Fingerprint, CustomsCertificateManager.fingerprint(try fixture.authority.publicDER()))
            XCTAssertNotEqual(try Data(contentsOf: fixture.keyURL), oldKey)
            XCTAssertFalse(recovered.isTrusted)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testResetRecoversDamagedCertificateAfterPreviouslyDisplayingFingerprint() async throws {
        try await withFixture { fixture in
            let previous = try await prepare(fixture)
            try Data("damaged after metadata was cached".utf8).write(to: fixture.authority.certificateURL)
            fixture.vm.refreshCertificateStatus()
            await fixture.vm.certificateTask?.value
            XCTAssertNotNil(fixture.vm.certificateError)
            XCTAssertEqual(fixture.vm.certificateInfo?.sha256Fingerprint, previous.sha256Fingerprint)
            fixture.vm.resetCertificate()
            await fixture.vm.certificateTask?.value
            XCTAssertNil(fixture.vm.certificateError)
            let recovered = try XCTUnwrap(fixture.vm.certificateInfo)
            XCTAssertNotEqual(recovered.sha256Fingerprint, previous.sha256Fingerprint)
            XCTAssertEqual(recovered.sha256Fingerprint, CustomsCertificateManager.fingerprint(try fixture.authority.publicDER()))
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testResetWhileProxyActivePreservesCA() async throws {
        try await withFixture { fixture in
            let info = try await prepare(fixture)
            let certificate = try Data(contentsOf: fixture.authority.certificateURL)
            let key = try Data(contentsOf: fixture.keyURL)
            fixture.vm.portText = String(try unusedLoopbackPort())
            fixture.vm.listenOnLAN = false
            fixture.vm.decryptHTTPS = false // Proxy's default shared authority is never prepared or used for TLS.
            fixture.vm.toggleProxy()
            try await waitForProxyStart(fixture.vm)
            let task = fixture.vm.certificateTask
            fixture.vm.resetCertificate()
            XCTAssertTrue(fixture.vm.isRunning)
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertEqual(fixture.vm.certificateTask, task)
            XCTAssertNotNil(fixture.vm.message)
            XCTAssertEqual(fixture.vm.certificateInfo?.sha256Fingerprint, info.sha256Fingerprint)
            XCTAssertEqual(try Data(contentsOf: fixture.authority.certificateURL), certificate)
            XCTAssertEqual(try Data(contentsOf: fixture.keyURL), key)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testResetWhileLoopbackDownloadActivePreservesFilesAndSession() async throws {
        try await withFixture { fixture in
            _ = try await prepare(fixture)
            let certificate = try Data(contentsOf: fixture.authority.certificateURL)
            let key = try Data(contentsOf: fixture.keyURL)
            fixture.vm.startCertificateDownload(listenOnLAN: false)
            await fixture.vm.certificateTask?.value
            let session = try XCTUnwrap(fixture.vm.downloadSession)
            XCTAssertEqual(session.addresses, ["127.0.0.1"])
            XCTAssertTrue(fixture.server.isRunning)
            let task = fixture.vm.certificateTask
            fixture.vm.resetCertificate()
            XCTAssertEqual(fixture.vm.certificateTask, task)
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertEqual(fixture.vm.downloadSession, session)
            XCTAssertTrue(fixture.server.isRunning)
            XCTAssertEqual(try Data(contentsOf: fixture.authority.certificateURL), certificate)
            XCTAssertEqual(try Data(contentsOf: fixture.keyURL), key)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
            fixture.vm.stopCertificateDownload()
            XCTAssertNil(fixture.vm.downloadSession)
            XCTAssertFalse(fixture.server.isRunning)
        }
    }

    @MainActor func testDownloadExpiryClearsPublishedSession() async throws {
        try await withFixture { fixture in
            _ = try await prepare(fixture)
            fixture.vm.startCertificateDownload(listenOnLAN: false, duration: 0.25)
            await fixture.vm.certificateTask?.value
            XCTAssertNotNil(fixture.vm.downloadSession)
            try await Task.sleep(for: .seconds(0.5))
            XCTAssertNil(fixture.vm.downloadSession)
            XCTAssertFalse(fixture.server.isRunning)
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertNotNil(fixture.vm.certificateInfo)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testImmediateStopDuringDownloadPreparationCannotResurrectListener() async throws {
        try await withFixture { fixture in
            _ = try await prepare(fixture)
            fixture.vm.startCertificateDownload(listenOnLAN: false)
            let pending = try XCTUnwrap(fixture.vm.certificateTask)
            XCTAssertTrue(fixture.vm.certificateBusy)
            // No suspension before stop: the MainActor result cannot be published first.
            fixture.vm.stopCertificateDownload()
            await pending.value
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertNil(fixture.vm.downloadSession)
            XCTAssertFalse(fixture.server.isRunning)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testImmediateShutdownDuringDownloadPreparationCannotResurrectListener() async throws {
        try await withFixture { fixture in
            _ = try await prepare(fixture)
            fixture.vm.startCertificateDownload(listenOnLAN: false)
            let pending = try XCTUnwrap(fixture.vm.certificateTask)
            fixture.vm.shutdown()
            await pending.value
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertNil(fixture.vm.downloadSession)
            XCTAssertFalse(fixture.server.isRunning)
            XCTAssertFalse(fixture.vm.isRunning)
            XCTAssertFalse(fixture.vm.isStarting)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testRemoveUserTrustStopsDownloadAndNeverTargetsAdministratorDomain() async throws {
        try await withFixture(userTrustPresent: true) { fixture in
            let info = try await prepare(fixture)
            let der = try fixture.authority.publicDER()
            fixture.vm.startCertificateDownload(listenOnLAN: false)
            await fixture.vm.certificateTask?.value
            XCTAssertNotNil(fixture.vm.downloadSession)
            fixture.vm.removeCertificateTrust()
            XCTAssertNil(fixture.vm.downloadSession)
            XCTAssertFalse(fixture.server.isRunning)
            await fixture.vm.certificateTask?.value
            XCTAssertNil(fixture.vm.certificateError)
            let calls = fixture.executor.calls
            XCTAssertEqual(calls.count, 2)
            let removal = try XCTUnwrap(calls.first)
            let deletion = try XCTUnwrap(calls.last)
            XCTAssertEqual(removal.arguments.first, "remove-trusted-cert")
            XCTAssertEqual(removal.arguments.count, 2)
            XCTAssertEqual(removal.certificate, der)
            let login = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
            XCTAssertEqual(deletion.arguments, ["delete-certificate", "-Z", info.sha256Fingerprint, login])
            XCTAssertTrue(calls.allSatisfy { $0.executable.path == "/usr/bin/security" })
            XCTAssertFalse(calls.flatMap(\.arguments).contains("-d"))
            XCTAssertFalse(calls.flatMap(\.arguments).contains { $0.contains("System.keychain") })
            XCTAssertEqual(try fixture.authority.publicDER(), der)
            XCTAssertFalse(fixture.vm.certificateInfo?.isTrusted ?? true)
        }
    }

    @MainActor func testInstallRejectsExternallyRotatedCertificateWithoutCommand() async throws {
        try await withFixture { fixture in
            let confirmed = try await prepare(fixture)
            let rotatedDER = try fixture.authority.rotate()
            XCTAssertNotEqual(CustomsCertificateManager.fingerprint(rotatedDER), confirmed.sha256Fingerprint)
            fixture.vm.installCertificate()
            await fixture.vm.certificateTask?.value
            XCTAssertNotNil(fixture.vm.certificateError)
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertEqual(fixture.vm.certificateInfo?.sha256Fingerprint, confirmed.sha256Fingerprint)
            XCTAssertEqual(try fixture.authority.publicDER(), rotatedDER)
            XCTAssertTrue(fixture.executor.calls.isEmpty)
        }
    }

    @MainActor func testBusyInstallBlocksProxyAndReentrantOperationsWithoutReplacingTask() async throws {
        try await withFixture { fixture in
            let confirmed = try await prepare(fixture)
            let der = try fixture.authority.publicDER()
            let readsBefore = fixture.inspector.reads
            fixture.vm.installCertificate()
            let pending = try XCTUnwrap(fixture.vm.certificateTask)
            XCTAssertTrue(fixture.vm.certificateBusy)
            fixture.vm.toggleProxy()
            fixture.vm.refreshCertificateStatus()
            fixture.vm.prepareCertificate()
            fixture.vm.startCertificateDownload(listenOnLAN: false)
            XCTAssertFalse(fixture.vm.isRunning)
            XCTAssertFalse(fixture.vm.isStarting)
            XCTAssertNil(fixture.vm.downloadSession)
            XCTAssertEqual(fixture.vm.certificateTask, pending)
            await pending.value
            XCTAssertFalse(fixture.vm.certificateBusy)
            XCTAssertNil(fixture.vm.certificateError)
            XCTAssertEqual(fixture.inspector.reads, readsBefore + 1)
            XCTAssertEqual(fixture.vm.certificateInfo?.sha256Fingerprint, confirmed.sha256Fingerprint)
            XCTAssertFalse(fixture.vm.certificateInfo?.isTrusted ?? true)
            let calls = fixture.executor.calls
            XCTAssertEqual(calls.count, 1)
            let call = try XCTUnwrap(calls.first)
            let login = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
            XCTAssertEqual(call.executable.path, "/usr/bin/security")
            XCTAssertEqual(Array(call.arguments.prefix(7)), ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", login])
            XCTAssertEqual(call.certificate, der)
            XCTAssertFalse(call.arguments.contains("-d"))
            XCTAssertFalse(call.arguments.contains { $0.contains("System.keychain") || $0.hasSuffix(".key") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(call.arguments.last)))
        }
    }
}
