import Foundation
import Security
import Darwin

/// No trust-store changes are performed. Export certificateURL only, never the key or PKCS#12.
nonisolated final class CustomsCertificateAuthority: @unchecked Sendable {
    static let shared = CustomsCertificateAuthority()
    private let lock = NSRecursiveLock()
    private var identities: [String: (SecIdentity, Date)] = [:]
    // Content fingerprints bind all cached leaves to the validated CA pair.
    private var validatedCertificate: Data?
    private var validatedKey: Data?
    private var validatedAt: Date?
    private let root: URL
    var certificateURL: URL { root.appendingPathComponent("KriaCustomsCA.crt") }
    private var keyURL: URL { root.appendingPathComponent("KriaCustomsCA.key") }
    init(directory: URL? = nil) {
        let requested = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kria/Customs/Certificates", isDirectory: true)
        // macOS's root-owned /var and /tmp aliases are not user CA symlinks. Canonicalize only
        // those fixed OS aliases, never arbitrary user paths (which must still be rejected).
        let path = requested.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
            root = URL(fileURLWithPath: "/private" + path, isDirectory: true)
        } else { root = requested }
    }
    func prepare() throws {
        lock.lock(); defer { lock.unlock() }
        try prepareLocked()
    }
    /// Serializes manager operations with preparation and all leaf signing, including across managers.
    func coordinated<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }

    private func clearCache() {
        identities.removeAll(); validatedCertificate = nil; validatedKey = nil; validatedAt = nil
    }

    private func checkAncestors() throws {
        var path = root
        while path.path != "/" {
            var info = stat()
            if lstat(path.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw CustomsBackendError.message("CA 路径不能经过符号链接或非目录: \(path.path)")
                }
            } else if errno != ENOENT { throw CustomsBackendError.system("检查 CA 路径") }
            path.deleteLastPathComponent()
        }
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Safe public-only read for revocation, even when the key is missing, damaged, or mismatched.
    /// No generation, key access, or private-key openssl invocation occurs here.
    func existingCertificateDER() throws -> Data? {
        try coordinated {
            try checkAncestors()
            guard exists(root) else { return nil }
            try protect(root, directory: true)
            guard exists(certificateURL) else { return nil }
            return try readCertificateLocked()
        }
    }

    /// Reads exactly one public certificate; never generates, validates expiry, or exports private material.
    /// A missing pair returns nil; a partial/damaged pair must be explicitly reset.
    func existingPublicDER() throws -> Data? {
        try coordinated {
            try checkAncestors()
            guard exists(root) else { return nil }
            try protect(root, directory: true)
            guard exists(certificateURL) || exists(keyURL) else { return nil }
            guard exists(certificateURL), exists(keyURL) else {
                clearCache()
                throw CustomsBackendError.message("本地 CA 文件不完整，请在海关中重置 CA")
            }
            let der = try readCertificateLocked()
            try protect(keyURL)
            let certificatePublicKey = try openssl(["x509", "-in", certificateURL.path, "-pubkey", "-noout"], directory: root)
            let privatePublicKey = try openssl(["pkey", "-in", keyURL.path, "-pubout"], directory: root)
            guard certificatePublicKey == privatePublicKey else {
                clearCache()
                throw CustomsBackendError.message("CA 证书和私钥损坏或不匹配，请在海关中重置 CA")
            }
            return der
        }
    }

    func publicDER() throws -> Data {
        guard let der = try existingPublicDER() else {
            throw CustomsBackendError.message("尚未生成本地 CA，请先准备证书")
        }
        return der
    }

    private func readCertificateLocked() throws -> Data {
        try protect(certificateURL)
        let data = try Data(contentsOf: certificateURL)
        guard data.count <= 128 * 1024 else { throw CustomsBackendError.message("CA 证书过大，请在海关中重置 CA") }
        let der: Data
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(begin), trimmed.hasSuffix(end) else {
                throw CustomsBackendError.message("CA 必须仅包含一张公钥证书，请在海关中重置 CA")
            }
            let body = trimmed.dropFirst(begin.count).dropLast(end.count)
            let base64 = body.filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: base64) else {
                throw CustomsBackendError.message("CA 证书损坏或包含额外材料，请在海关中重置 CA")
            }
            der = decoded
        } else { der = data }
        // Security may tolerate trailing bytes: enforce exactly one DER SEQUENCE ourselves.
        let bytes = [UInt8](der)
        guard bytes.count >= 2, bytes[0] == 0x30 else {
            throw CustomsBackendError.message("CA 必须是单张 DER 证书，请在海关中重置 CA")
        }
        let lengthBytes = bytes[1] & 0x80 == 0 ? 0 : Int(bytes[1] & 0x7f)
        guard lengthBytes <= 4, bytes.count >= 2 + lengthBytes,
              bytes[1] != 0x80 else { throw CustomsBackendError.message("CA DER 长度损坏，请在海关中重置 CA") }
        let length = lengthBytes == 0 ? Int(bytes[1]) : bytes[2..<(2 + lengthBytes)].reduce(0) { $0 * 256 + Int($1) }
        guard length + 2 + lengthBytes == bytes.count else {
            throw CustomsBackendError.message("CA 包含多张证书或额外材料，请在海关中重置 CA")
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              SecCertificateCopyData(certificate) as Data == der else {
            throw CustomsBackendError.message("CA 证书损坏，请在海关中重置 CA")
        }
        return der
    }

    /// Stages and validates a new pair before touching trust or old files. Caller removes only old DER trust.
    /// Atomic directory exchange is inside the same lock as leaf signing. Unknown entries are preserved.
    /// Unreadable old certificate yields nil: no guessed subject-based trust changes are possible.
    @discardableResult
    func rotate(beforeReplacing: (Data?) throws -> Void = { _ in }) throws -> Data {
        try coordinated {
            try checkAncestors()
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try protect(root, directory: true)
            for file in [certificateURL, keyURL] where exists(file) { try protect(file) }
            // A damaged key must not prevent removal of trust for a still-readable old certificate.
            let oldDER = exists(certificateURL) ? try? readCertificateLocked() : nil
            let stage = root.deletingLastPathComponent().appendingPathComponent(".customs-rotate-\(UUID().uuidString)", isDirectory: true)
            let replacement = CustomsCertificateAuthority(directory: stage)
            defer {
                // Never recursively delete unknown entries if rollback itself fails.
                for name in ["KriaCustomsCA.crt", "KriaCustomsCA.key"] {
                    try? fm.removeItem(at: stage.appendingPathComponent(name))
                }
                if (try? fm.contentsOfDirectory(atPath: stage.path).isEmpty) == true { try? fm.removeItem(at: stage) }
            }
            try replacement.prepare()
            let newDER = try replacement.publicDER()
            try beforeReplacing(oldDER)
            var moved: [String] = []
            do {
                for name in try fm.contentsOfDirectory(atPath: root.path)
                    where name != certificateURL.lastPathComponent && name != keyURL.lastPathComponent {
                    try fm.moveItem(at: root.appendingPathComponent(name), to: stage.appendingPathComponent(name))
                    moved.append(name)
                }
                guard renameatx_np(AT_FDCWD, root.path, AT_FDCWD, stage.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw CustomsBackendError.system("原子替换 CA 目录")
                }
            } catch {
                for name in moved.reversed() {
                    try fm.moveItem(at: stage.appendingPathComponent(name), to: root.appendingPathComponent(name))
                }
                throw error
            }
            clearCache()
            return newDER
        }
    }

    private func protect(_ url: URL, directory: Bool = false) throws {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else {
            throw CustomsBackendError.message("证书路径必须是当前用户拥有的普通文件/目录（不接受符号链接）: \(url.path)")
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              attributes.st_uid == getuid(), directory || attributes.st_nlink == 1 else {
            throw CustomsBackendError.message("证书文件必须由当前用户拥有，且不能是符号链接或共享硬链接: \(url.path)")
        }
        guard fchmod(descriptor, directory ? 0o700 : 0o600) == 0 else { throw CustomsBackendError.system("保护证书权限") }
    }
    /// Provides a private, single-public-certificate snapshot for security CLI operations.
    func withPublicCertificate<T>(der: Data, _ operation: (URL) throws -> T) throws -> T {
        try coordinated {
            try checkAncestors()
            try protect(root, directory: true)
            let work = root.appendingPathComponent("public-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: work) }
            let file = work.appendingPathComponent("CA.crt")
            guard FileManager.default.createFile(atPath: file.path, contents: der, attributes: [.posixPermissions: 0o600]) else {
                throw CustomsBackendError.message("无法创建公钥证书快照")
            }
            return try operation(file)
        }
    }

    private func prepareLocked() throws {
        try checkAncestors()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try protect(root, directory: true)
        let fm = FileManager.default
        if exists(certificateURL) || exists(keyURL) {
            guard exists(certificateURL), exists(keyURL) else {
                identities.removeAll(); validatedCertificate = nil; validatedKey = nil; validatedAt = nil
                throw CustomsBackendError.message("本地 CA 文件不完整，请在海关中重置 CA")
            }
            try protect(keyURL); try protect(certificateURL)
            let certificateData = try Data(contentsOf: certificateURL)
            let keyData = try Data(contentsOf: keyURL)
            if certificateData == validatedCertificate, keyData == validatedKey,
               let validatedAt, Date().timeIntervalSince(validatedAt) < 3600 { return }
            identities.removeAll(); validatedCertificate = nil; validatedKey = nil; validatedAt = nil
            try openssl(["x509", "-in", certificateURL.path, "-checkend", "86400", "-noout"], directory: root)
            let certificatePublicKey = try openssl(["x509", "-in", certificateURL.path, "-pubkey", "-noout"], directory: root)
            let privatePublicKey = try openssl(["pkey", "-in", keyURL.path, "-pubout"], directory: root)
            guard certificatePublicKey == privatePublicKey else { throw CustomsBackendError.message("CA 证书和私钥不匹配，请在海关中重置 CA") }
            validatedCertificate = certificateData; validatedKey = keyData; validatedAt = Date()
            return
        }
        identities.removeAll(); validatedCertificate = nil; validatedKey = nil; validatedAt = nil
        let work = root.appendingPathComponent("generate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let config = work.appendingPathComponent("ca.cnf")
        try Data("""
        [req]
        distinguished_name=dn
        x509_extensions=ca
        prompt=no
        [dn]
        CN=Kria Customs Local CA
        O=Kria Local Debugging
        [ca]
        basicConstraints=critical,CA:TRUE,pathlen:0
        keyUsage=critical,keyCertSign,cRLSign
        subjectKeyIdentifier=hash
        authorityKeyIdentifier=keyid:always
        """.utf8).write(to: config)
        let key = work.appendingPathComponent("ca.key"), cert = work.appendingPathComponent("ca.crt")
        // Precreate private output securely; openssl preserves the mode when overwriting it.
        guard fm.createFile(atPath: key.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CustomsBackendError.message("无法创建 CA 私钥")
        }
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                     "-config", config.path, "-keyout", key.path, "-out", cert.path], directory: work)
        try protect(key); try protect(cert)
        try fm.moveItem(at: key, to: keyURL)
        do { try fm.moveItem(at: cert, to: certificateURL) }
        catch { try? fm.removeItem(at: keyURL); throw error }
        validatedCertificate = try Data(contentsOf: certificateURL)
        validatedKey = try Data(contentsOf: keyURL)
        validatedAt = Date()
    }
    static func validatedHost(_ input: String) throws -> String {
        let host = input.lowercased()
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 { return host }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw CustomsBackendError.message("无效 TLS 主机名（请使用 ASCII/IDNA 域名）: \(input)") }
        return host
    }
    func identity(for hostname: String) throws -> SecIdentity {
        let host = try Self.validatedHost(hostname)
        lock.lock(); defer { lock.unlock() }
        try prepareLocked()
        if let existing = identities[host], Date().timeIntervalSince(existing.1) < 6 * 86400 { return existing.0 }
        let fm = FileManager.default
        let work = root.appendingPathComponent("leaf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let key = work.appendingPathComponent("leaf.key"), csr = work.appendingPathComponent("leaf.csr")
        let cert = work.appendingPathComponent("leaf.crt"), p12 = work.appendingPathComponent("leaf.p12")
        for file in [key, p12] {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CustomsBackendError.message("无法创建临时证书私钥文件")
            }
        }
        var ip4 = in_addr(), ip6 = in6_addr()
        let ip = inet_pton(AF_INET, host, &ip4) == 1 || inet_pton(AF_INET6, host, &ip6) == 1
        let config = work.appendingPathComponent("leaf.cnf")
        try Data("""
        [req]
        distinguished_name=dn
        prompt=no
        [dn]
        CN=Kria Customs Leaf
        [leaf]
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=\(ip ? "IP" : "DNS"):\(host)
        subjectKeyIdentifier=hash
        authorityKeyIdentifier=keyid,issuer
        """.utf8).write(to: config)
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-config", config.path,
                     "-keyout", key.path, "-out", csr.path], directory: work)
        let serial = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try openssl(["x509", "-req", "-in", csr.path, "-CA", certificateURL.path, "-CAkey", keyURL.path,
                     "-set_serial", "0x\(serial)", "-days", "7", "-sha256", "-extfile", config.path,
                     "-extensions", "leaf", "-out", cert.path], directory: work)
        let password = UUID().uuidString
        try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-certfile", certificateURL.path,
                     "-out", p12.path, "-passout", "pass:\(password)", "-keypbe", "PBE-SHA1-3DES",
                     "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"], directory: work)
        var items: CFArray?
        // The app requires macOS 15.6; import only into memory, never user keychains.
        let options: [String: Any] = [kSecImportExportPassphrase as String: password,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let item = (items as? [[String: Any]])?.first,
              let value = item[kSecImportItemIdentity as String] else {
            throw CustomsBackendError.message("导入 TLS 证书失败: \(status)")
        }
        let identity = value as! SecIdentity
        if identities.count >= 128 { identities.removeAll() }
        identities[host] = (identity, Date())
        return identity
    }
    @discardableResult
    private func openssl(_ arguments: [String], directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let output = directory.appendingPathComponent("openssl-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CustomsBackendError.message("不能创建 openssl 输出文件")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let file = try FileHandle(forWritingTo: output); defer { try? file.close() }
        process.standardOutput = file; process.standardError = file
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 20) != .success {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success { _ = Darwin.kill(process.processIdentifier, SIGKILL); finished.wait() }
            throw CustomsBackendError.message("生成本地证书超时")
        }
        let data = try Data(contentsOf: output)
        guard process.terminationStatus == 0 else {
            throw CustomsBackendError.message("openssl 证书操作失败（已有 CA 损坏或过期时，请在海关中重置 CA）: \(String(decoding: data.prefix(4096), as: UTF8.self))")
        }
        return data
    }
}
