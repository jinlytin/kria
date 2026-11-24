import Foundation
import Security
import CryptoKit
import Darwin

nonisolated struct CustomsCertificateInfo: Sendable {
    let subject: String
    let serialNumber: String
    /// Uppercase SHA-256 hex, without separators; also used for exact keychain deletion.
    let sha256Fingerprint: String
    let validFrom: Date
    let validUntil: Date
    let isTrusted: Bool
    /// Presence of explicit settings, including deny/unspecified; not an assertion of effective trust.
    let userTrusted: Bool
    let adminTrusted: Bool
    let certificatePath: String
    var isExpired: Bool { validUntil <= Date() }
    var userTrustSettingsPresent: Bool { userTrusted }
    var adminTrustSettingsPresent: Bool { adminTrusted }
}

nonisolated struct CustomsCertificateTrustStatus: Sendable {
    let isTrusted: Bool
    let userTrusted: Bool
    let adminTrusted: Bool
    let loginCertificatePresent: Bool
}

nonisolated struct CustomsCertificateCommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
    init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.exitCode = exitCode; self.standardOutput = standardOutput; self.standardError = standardError
    }
}

nonisolated protocol CustomsCertificateCommandExecuting: Sendable {
    func execute(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CustomsCertificateCommandResult
}

/// No shell, no password input, a minimal environment, and independently drained bounded pipes.
nonisolated final class CustomsCertificateProcessExecutor: CustomsCertificateCommandExecuting, @unchecked Sendable {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        private var data = Data()
        func drain(_ handle: FileHandle) {
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty {
                lock.lock()
                data.append(chunk.prefix(max(0, 64 * 1024 - data.count)))
                lock.unlock()
            }
        }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }
    func execute(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CustomsCertificateCommandResult {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let out = Output(), err = Output(), drains = DispatchGroup()
        drains.enter(); DispatchQueue.global().async { out.drain(stdout.fileHandleForReading); drains.leave() }
        drains.enter(); DispatchQueue.global().async { err.drain(stderr.fileHandleForReading); drains.leave() }
        let timedOut = done.wait(timeout: .now() + max(0.01, timeout)) != .success
        if timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
        }
        // security does not spawn output-owning children; bound this wait for injectable/non-security commands.
        if drains.wait(timeout: .now() + 5) != .success {
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            throw CustomsBackendError.message("证书命令输出管道未关闭")
        }
        if timedOut { throw CustomsBackendError.message("证书操作超时（授权等待最多 120 秒）；系统信任可能已变更，请重新检查状态") }
        return .init(exitCode: process.terminationStatus, standardOutput: out.value, standardError: err.value)
    }
}

/// Synchronous background API. VM must stop proxy/download and obtain explicit confirmation before reset.
nonisolated final class CustomsCertificateManager: @unchecked Sendable {
    typealias TrustInspector = @Sendable (Data, URL) throws -> CustomsCertificateTrustStatus
    let authority: CustomsCertificateAuthority
    private let executor: any CustomsCertificateCommandExecuting
    private let trustInspector: TrustInspector
    private let loginKeychain: URL
    init(authority: CustomsCertificateAuthority = .shared,
         executor: any CustomsCertificateCommandExecuting = CustomsCertificateProcessExecutor(),
         trustInspector: @escaping TrustInspector = CustomsCertificateManager.systemTrustStatus) {
        self.authority = authority; self.executor = executor; self.trustInspector = trustInspector
        loginKeychain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")
    }

    func inspect() throws -> CustomsCertificateInfo? {
        try authority.coordinated {
            guard let der = try authority.existingPublicDER() else { return nil }
            return try info(der)
        }
    }
    func prepare() throws -> CustomsCertificateInfo {
        try authority.coordinated {
            try authority.prepare()
            return try info(authority.publicDER())
        }
    }
    /// Bind mutations to the certificate the user confirmed. With an expected fingerprint,
    /// a missing/replaced certificate is an error, never permission to auto-generate another CA.
    func installAndTrust(expectedFingerprint: String? = nil) throws -> CustomsCertificateInfo {
        try authority.coordinated {
            if expectedFingerprint != nil {
                try checkFingerprint(authority.existingCertificateDER(), expected: expectedFingerprint)
            }
            try authority.prepare()
            let der = try authority.publicDER()
            try checkFingerprint(der, expected: expectedFingerprint)
            try authority.withPublicCertificate(der: der) { file in
                try command(["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", loginKeychain.path, file.path])
            }
            return try info(der)
        }
    }
    func removeUserTrust(expectedFingerprint: String? = nil) throws -> CustomsCertificateInfo? {
        try authority.coordinated {
            let currentDER = try authority.existingCertificateDER()
            try checkFingerprint(currentDER, expected: expectedFingerprint)
            guard let der = currentDER else { return nil }
            try remove(der: der)
            return try info(der)
        }
    }
    func reset(expectedFingerprint: String? = nil) throws -> CustomsCertificateInfo {
        try authority.coordinated {
            if expectedFingerprint != nil {
                try checkFingerprint(authority.existingCertificateDER(), expected: expectedFingerprint)
            }
            var removalAttempted = false, removalCompleted = false, replaced = false
            do {
                let der = try authority.rotate { oldDER in
                    try self.checkFingerprint(oldDER, expected: expectedFingerprint)
                    guard let oldDER else { return }
                    let status = try self.trustInspector(oldDER, self.loginKeychain)
                    guard !status.adminTrusted else {
                        throw CustomsBackendError.message("当前 CA 存在管理员域信任设置，请先在钥匙串访问中手动移除该精确证书的管理员信任，再重置")
                    }
                    removalAttempted = status.userTrusted || status.loginCertificatePresent
                    try self.remove(der: oldDER, status: status)
                    removalCompleted = removalAttempted
                }
                replaced = true
                return try info(der)
            } catch {
                let detail: String
                if replaced { detail = "新 CA 已替换成功，但读取信任状态失败" }
                else if removalCompleted { detail = "原 CA 文件仍可用；旧 CA 用户信任/登录钥匙串证书已移除" }
                else if removalAttempted { detail = "原 CA 文件未替换；用户信任可能已部分移除，请重新检查状态" }
                else { detail = "原 CA 文件未替换，未执行用户信任修改" }
                throw CustomsBackendError.message("CA 重置失败：\(detail)。\(error.localizedDescription)")
            }
        }
    }

    private func checkFingerprint(_ der: Data?, expected: String?) throws {
        guard let expected else { return }
        guard let der, Self.fingerprint(der) == expected else {
            throw CustomsBackendError.message("本地 CA 与确认的证书指纹不一致或已不存在；未执行证书变更，请刷新状态后重新确认")
        }
    }

    private func remove(der: Data, status supplied: CustomsCertificateTrustStatus? = nil) throws {
        let status = try supplied ?? trustInspector(der, loginKeychain)
        do {
            if status.userTrusted {
                try authority.withPublicCertificate(der: der) { file in
                    try command(["remove-trusted-cert", file.path])
                }
            }
            if status.loginCertificatePresent {
                // security help explicitly documents SHA-256 OR SHA-1 for -Z on this platform.
                // Always pass the full 64-character SHA-256 and the one login keychain; never subject/-t/-d.
                try command(["delete-certificate", "-Z", Self.fingerprint(der), loginKeychain.path])
            }
        } catch {
            throw CustomsBackendError.message("移除当前 CA 失败，用户域信任可能已部分变更（管理员域未修改），请重新检查：\(error.localizedDescription)")
        }
    }
    private func command(_ arguments: [String]) throws {
        let result = try executor.execute(executable: URL(fileURLWithPath: "/usr/bin/security"), arguments: arguments, timeout: 120)
        guard result.exitCode == 0 else {
            let text = String(decoding: result.standardError.prefix(4096), as: UTF8.self)
            throw CustomsBackendError.message("用户域证书操作失败（\(result.exitCode)）；可能未授权或取消，请重新检查状态。\(text)")
        }
    }
    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
    private func info(_ der: Data) throws -> CustomsCertificateInfo {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CustomsBackendError.message("CA 证书损坏，请在海关中重置 CA")
        }
        var error: Unmanaged<CFError>?
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1SerialNumber, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter]
        guard let values = SecCertificateCopyValues(certificate, keys as CFArray, &error) as? [String: Any] else {
            throw CustomsBackendError.message("无法读取 CA 元数据：\(error?.takeRetainedValue().localizedDescription ?? "未知错误")")
        }
        func value(_ key: CFString) -> Any? { (values[key as String] as? [String: Any])?[kSecPropertyKeyValue as String] }
        func date(_ key: CFString) throws -> Date {
            if let date = value(key) as? Date { return date }
            if let number = value(key) as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
            throw CustomsBackendError.message("CA 有效期元数据损坏，请在海关中重置 CA")
        }
        let subjectFields = value(kSecOIDX509V1SubjectName) as? [[String: Any]] ?? []
        let subject = subjectFields.compactMap { field -> String? in
            guard let label = field[kSecPropertyKeyLabel as String] as? String,
                  let value = field[kSecPropertyKeyValue as String] as? String else { return nil }
            return "\(label)=\(value)"
        }.joined(separator: ", ")
        let serial: String
        if let data = value(kSecOIDX509V1SerialNumber) as? Data {
            serial = data.map { String(format: "%02X", $0) }.joined()
        } else if let text = value(kSecOIDX509V1SerialNumber) as? String { serial = text }
        else { throw CustomsBackendError.message("CA 序列号元数据损坏，请在海关中重置 CA") }
        let status = try trustInspector(der, loginKeychain)
        return .init(subject: subject.isEmpty ? (SecCertificateCopySubjectSummary(certificate) as String? ?? "未知 CA") : subject,
                     serialNumber: serial, sha256Fingerprint: Self.fingerprint(der),
                     validFrom: try date(kSecOIDX509V1ValidityNotBefore), validUntil: try date(kSecOIDX509V1ValidityNotAfter),
                     isTrusted: status.isTrusted, userTrusted: status.userTrusted, adminTrusted: status.adminTrusted,
                     certificatePath: authority.certificateURL.path)
    }

    /// Evaluates SSL CA trust against the current Mac stores. No custom anchors, verify-date overrides,
    /// allowed errors, hostname mismatch exceptions, or network fetch. This is CA status, not a leaf/host check.
    static func systemTrustStatus(_ der: Data, _ loginKeychain: URL) throws -> CustomsCertificateTrustStatus {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CustomsBackendError.message("无法读取 CA 公钥")
        }
        func explicit(_ domain: SecTrustSettingsDomain) throws -> Bool {
            var settings: CFArray?
            let status = SecTrustSettingsCopyTrustSettings(certificate, domain, &settings)
            if status == errSecItemNotFound || status == errSecNoTrustSettings { return false }
            guard status == errSecSuccess else { throw CustomsBackendError.message("无法读取信任设置: \(status)") }
            return true // Empty settings means explicit trustRoot; deny must still block admin reset.
        }
        var trust: SecTrust?
        let creation = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust)
        guard creation == errSecSuccess, let trust else { throw CustomsBackendError.message("创建 CA 信任检查失败: \(creation)") }
        let fetch = SecTrustSetNetworkFetchAllowed(trust, false)
        guard fetch == errSecSuccess else { throw CustomsBackendError.message("关闭信任检查网络请求失败: \(fetch)") }
        var trustError: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &trustError)
        var keychain: SecKeychain?
        let open = SecKeychainOpen(loginKeychain.path, &keychain)
        var present = false
        if open == errSecSuccess, let keychain {
            let query: [String: Any] = [kSecClass as String: kSecClassCertificate,
                kSecMatchSearchList as String: [keychain], kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnRef as String: true]
            var result: CFTypeRef?
            let found = SecItemCopyMatching(query as CFDictionary, &result)
            if found == errSecSuccess, let certificates = result as? [SecCertificate] {
                present = certificates.contains { SecCertificateCopyData($0) as Data == der }
            } else if found != errSecItemNotFound {
                throw CustomsBackendError.message("读取登录钥匙串证书失败: \(found)")
            }
        } else if open != errSecNoSuchKeychain {
            throw CustomsBackendError.message("打开登录钥匙串失败: \(open)")
        }
        return .init(isTrusted: trusted, userTrusted: try explicit(.user), adminTrusted: try explicit(.admin), loginCertificatePresent: present)
    }
}
