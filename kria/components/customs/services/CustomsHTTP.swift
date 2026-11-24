import Foundation

nonisolated enum CustomsHTTP {
    static let captureLimit = 512 * 1024
    static let headerLimit = 64 * 1024
    static let forbiddenHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "upgrade", "proxy-connection",
        "proxy-authorization", "proxy-authenticate", "keep-alive", "te", "trailer", "expect"
    ]
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
            Array("!#$%&'*+-.^_`|~".utf8).contains($0)
        }
    }
    static func validateRule(_ rule: CustomsHeaderRule) -> String? {
        guard validName(rule.name) else { return "Header 名称必须是合法 HTTP token" }
        guard !forbiddenHeaders.contains(rule.name.lowercased()), !rule.name.lowercased().hasPrefix("proxy-") else {
            return "不允许改写代理、连接或报文边界字段"
        }
        guard !rule.value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 || $0 == 127 || ($0 < 32 && $0 != 9) }) else {
            return "Header 值包含非法控制字符"
        }
        return nil
    }
    static func text(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { UnicodeScalar(UInt32($0))! }))
    }
    static func bytes(_ string: String) -> Data {
        // Existing wire text is Latin-1. New rule values are UTF-8, encoded separately.
        Data(string.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }
    struct Field: Sendable {
        var name: String
        var value: String
        var wire: Data
        var header: CustomsHeader { CustomsHeader(name: name, value: value) }
    }
    struct Head: Sendable {
        var firstLine: String
        var fields: [Field]
        var wire: Data {
            var data = CustomsHTTP.bytes(firstLine + "\r\n")
            for field in fields { data.append(field.wire); data.append(contentsOf: [13, 10]) }
            data.append(contentsOf: [13, 10]); return data
        }
        func values(_ name: String) -> [String] { fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value) }
        func tokens(_ name: String) -> [String] {
            values(name).flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        }
        var headers: [CustomsHeader] { fields.map(\.header) }
        var status: Int? {
            let parts = firstLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
                  parts[1].count == 3, let code = Int(parts[1]), (100...599).contains(code) else { return nil }
            return code
        }
        mutating func rewrite(rules: [CustomsHeaderRule], enabled: Bool) -> [String] {
            guard enabled else { return [] }
            let dynamicForbidden = Set(tokens("connection"))
            var rewritten: [String] = []
            for rule in rules where rule.isEnabled && !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard CustomsHTTP.validateRule(rule) == nil, !dynamicForbidden.contains(rule.name.lowercased()) else { continue }
                let indices = fields.indices.filter { fields[$0].name.caseInsensitiveCompare(rule.name) == .orderedSame }
                let insertion = indices.first ?? fields.count
                fields.removeAll { $0.name.caseInsensitiveCompare(rule.name) == .orderedSame }
                fields.insert(Field(name: rule.name, value: rule.value, wire: Data("\(rule.name): \(rule.value)".utf8)), at: min(insertion, fields.count))
                if !rewritten.contains(where: { $0.caseInsensitiveCompare(rule.name) == .orderedSame }) { rewritten.append(rule.name) }
            }
            return rewritten
        }
    }
    enum Framing: Equatable { case none, length(Int), chunked, close }
    static func framing(_ head: Head, responseTo method: String? = nil) throws -> Framing {
        let lengths = head.values("content-length").flatMap { $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
        var length: Int?
        for value in lengths {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), number >= 0,
                  length == nil || length == number else { throw CustomsBackendError.message("非法/冲突 Content-Length") }
            length = number
        }
        let encoding = head.tokens("transfer-encoding")
        guard encoding.isEmpty || length == nil else { throw CustomsBackendError.message("同时存在 Transfer-Encoding 和 Content-Length，拒绝歧义报文") }
        if let method {
            guard let status = head.status else { throw CustomsBackendError.message("非法 HTTP 响应状态行") }
            if method == "HEAD" || (100...199).contains(status) || status == 204 || status == 304 { return .none }
        }
        if !encoding.isEmpty {
            guard encoding.last == "chunked", encoding.filter({ $0 == "chunked" }).count == 1 else {
                throw CustomsBackendError.message("只支持以 chunked 结尾的 Transfer-Encoding")
            }
            return .chunked
        }
        if let length { return .length(length) }
        return method == nil ? .none : .close
    }
    struct Destination: Sendable {
        var host: String
        var port: UInt16
        var target: String
        var url: String
        var method: String
        var version: String
    }
    static func authority(_ raw: String, defaultPort: UInt16) throws -> (String, UInt16) {
        guard !raw.isEmpty, !raw.contains("@"), !raw.utf8.contains(where: { $0 <= 32 || $0 == 127 }),
              !raw.contains("/"), !raw.contains("\\"), !raw.contains("?"), !raw.contains("#") else {
            throw CustomsBackendError.message("非法目标 authority")
        }
        var host: String; var port = defaultPort
        if raw.first == "[" {
            guard let end = raw.firstIndex(of: "]") else { throw CustomsBackendError.message("非法 IPv6 authority") }
            host = String(raw[raw.index(after: raw.startIndex)..<end])
            let tail = raw[raw.index(after: end)...]
            if !tail.isEmpty {
                guard tail.first == ":", let number = UInt16(tail.dropFirst()), number > 0 else { throw CustomsBackendError.message("非法端口") }
                port = number
            }
        } else {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw CustomsBackendError.message("IPv6 地址需要方括号") }
            host = String(parts[0])
            if parts.count == 2 {
                guard let number = UInt16(parts[1]), number > 0 else { throw CustomsBackendError.message("非法端口") }
                port = number
            }
        }
        return (try CustomsCertificateAuthority.validatedHost(host), port)
    }
    static func destination(_ head: Head, tunnel: (String, UInt16)? = nil) throws -> Destination {
        let parts = head.firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, validName(String(parts[0])), parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            throw CustomsBackendError.message("只支持合法 HTTP/1.0、HTTP/1.1 请求行")
        }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard !target.isEmpty, target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !target.contains("#") else { throw CustomsBackendError.message("非法请求 target") }
        if method == "CONNECT" {
            guard tunnel == nil else { throw CustomsBackendError.message("不支持嵌套 CONNECT") }
            let (host, port) = try authority(target, defaultPort: 443)
            return Destination(host: host, port: port, target: target, url: "https://\(target)", method: method, version: version)
        }
        if target == "*" && method != "OPTIONS" {
            throw CustomsBackendError.message("仅 OPTIONS 允许 asterisk-form 请求 target")
        }
        if let tunnel {
            guard target.first == "/" || target == "*" else { throw CustomsBackendError.message("解密连接仅接受 origin-form 请求") }
            let hosts = head.values("host")
            guard hosts.count == 1 else { throw CustomsBackendError.message("需要唯一 Host header") }
            let parsed = try authority(hosts[0], defaultPort: 443)
            guard parsed.0 == tunnel.0, parsed.1 == tunnel.1 else { throw CustomsBackendError.message("Host 与 CONNECT 目标不一致") }
            return Destination(host: tunnel.0, port: tunnel.1, target: target, url: "https://\(hosts[0])\(target == "*" ? "/" : target)", method: method, version: version)
        }
        if target == "*" {
            let hosts = head.values("host")
            guard hosts.count == 1 else { throw CustomsBackendError.message("需要唯一 Host header") }
            let (host, port) = try authority(hosts[0], defaultPort: 80)
            return Destination(host: host, port: port, target: "*", url: "http://\(hosts[0])/", method: method, version: version)
        }
        guard target.lowercased().hasPrefix("http://") else { throw CustomsBackendError.message("HTTP 代理需要 http:// 绝对 URL；HTTPS 请使用 CONNECT") }
        let remainder = target.dropFirst(7)
        let boundary = remainder.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? remainder.endIndex
        let rawAuthority = String(remainder[..<boundary])
        let (host, port) = try authority(rawAuthority, defaultPort: 80)
        let tail = String(remainder[boundary...])
        let origin = tail.isEmpty ? "/" : (tail.first == "?" ? "/" + tail : tail)
        let hosts = head.values("host")
        guard hosts.count == 1 else { throw CustomsBackendError.message("需要唯一 Host header") }
        let parsed = try authority(hosts[0], defaultPort: 80)
        guard parsed.0 == host, parsed.1 == port else { throw CustomsBackendError.message("Host 与绝对 URL 不一致，拒绝歧义请求") }
        return Destination(host: host, port: port, target: origin, url: target, method: method, version: version)
    }
    static func matches(_ host: String, patterns: [String]) -> Bool {
        patterns.contains { input in
            let pattern = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst())
                return host.hasSuffix(suffix) && host.count > suffix.count
            }
            return host == pattern
        }
    }
}

/// Bounded lookahead. Body data is passed in 32 KiB blocks without buffering the whole upload.
// Single-reader ownership: transferred to the upload worker, never read concurrently.
nonisolated final class CustomsHTTPReader: @unchecked Sendable {
    let transport: any CustomsTransport
    private(set) var buffered = Data()
    init(_ transport: any CustomsTransport) { self.transport = transport }
    func takeBuffered() -> Data { let data = buffered; buffered.removeAll(keepingCapacity: true); return data }
    private func fill() throws -> Bool {
        let data = try transport.read(maximum: 32_768)
        if data.isEmpty { return false }
        buffered.append(data); return true
    }
    func line(maximum: Int = CustomsHTTP.headerLimit) throws -> Data {
        while true {
            if let range = buffered.range(of: Data([13, 10])) {
                guard buffered.distance(from: buffered.startIndex, to: range.upperBound) <= maximum else { throw CustomsBackendError.message("HTTP 行超过限制") }
                let data = buffered[..<range.lowerBound]
                buffered.removeSubrange(..<range.upperBound); return Data(data)
            }
            guard buffered.count <= maximum else { throw CustomsBackendError.message("HTTP 行超过限制") }
            guard try fill() else { throw CustomsBackendError.message("HTTP 行提前结束") }
        }
    }
    func head() throws -> CustomsHTTP.Head {
        let first = try line()
        var used = first.count + 2
        var fields: [CustomsHTTP.Field] = []
        guard !first.contains(0), !first.contains(10), !first.contains(13) else { throw CustomsBackendError.message("非法 HTTP 起始行") }
        while true {
            let data = try line(maximum: CustomsHTTP.headerLimit - used)
            used += data.count + 2
            guard used <= CustomsHTTP.headerLimit else { throw CustomsBackendError.message("HTTP headers 超过 64 KiB") }
            if data.isEmpty { break }
            guard let colon = data.firstIndex(of: 58), colon > data.startIndex else { throw CustomsBackendError.message("非法 Header / 不支持 obs-fold") }
            let name = CustomsHTTP.text(Data(data[..<colon]))
            let rawValue = data[data.index(after: colon)...]
            guard CustomsHTTP.validName(name), !rawValue.contains(where: { $0 == 0 || $0 == 13 || $0 == 10 || $0 == 127 || ($0 < 32 && $0 != 9) }) else {
                throw CustomsBackendError.message("Header 包含非法 token/控制字符")
            }
            fields.append(.init(name: name, value: CustomsHTTP.text(Data(rawValue)).trimmingCharacters(in: .whitespaces), wire: data))
        }
        return .init(firstLine: CustomsHTTP.text(first), fields: fields)
    }
    func block(maximum: Int) throws -> Data {
        if buffered.isEmpty { _ = try fill() }
        let count = min(maximum, buffered.count)
        let data = Data(buffered.prefix(count)); buffered.removeFirst(count); return data
    }
    func exact(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let data = try block(maximum: count - result.count)
            guard !data.isEmpty else { throw CustomsBackendError.message("HTTP body 提前结束") }
            result.append(data)
        }
        return result
    }
    func forward(_ framing: CustomsHTTP.Framing, to output: any CustomsTransport,
                 capture: (Data) -> Void) throws {
        func transfer(_ count: Int) throws {
            var remaining = count
            while remaining > 0 {
                let data = try block(maximum: min(remaining, 32_768))
                guard !data.isEmpty else { throw CustomsBackendError.message("Content-Length/chunk body 提前结束") }
                capture(data); try output.write(data); remaining -= data.count
            }
        }
        switch framing {
        case .none: return
        case .length(let count): try transfer(count)
        case .close:
            while true {
                let data = try block(maximum: 32_768)
                if data.isEmpty { return }
                capture(data); try output.write(data)
            }
        case .chunked:
            while true {
                let sizeLine = try line(maximum: 8192)
                guard !sizeLine.contains(where: { $0 < 32 || $0 == 127 }) else { throw CustomsBackendError.message("非法 chunk extension") }
                let sizeText = CustomsHTTP.text(sizeLine).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard !sizeText.isEmpty, sizeText.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let size = Int(sizeText, radix: 16), size >= 0 else { throw CustomsBackendError.message("非法 chunk size") }
                try output.write(sizeLine + Data([13, 10]))
                if size == 0 {
                    var trailerBytes = 0
                    while true {
                        let trailer = try line(maximum: CustomsHTTP.headerLimit - trailerBytes)
                        trailerBytes += trailer.count + 2
                        guard trailerBytes <= CustomsHTTP.headerLimit else { throw CustomsBackendError.message("chunk trailers 超过限制") }
                        if !trailer.isEmpty {
                            guard let colon = trailer.firstIndex(of: 58),
                                  CustomsHTTP.validName(CustomsHTTP.text(Data(trailer[..<colon]))),
                                  !trailer.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 || $0 == 127 || ($0 < 32 && $0 != 9) }) else {
                                throw CustomsBackendError.message("非法 chunk trailer")
                            }
                            let name = CustomsHTTP.text(Data(trailer[..<colon])).lowercased()
                            guard !CustomsHTTP.forbiddenHeaders.contains(name) else { throw CustomsBackendError.message("trailer 包含禁止的边界/连接字段") }
                        }
                        try output.write(trailer + Data([13, 10]))
                        if trailer.isEmpty { return }
                    }
                }
                try transfer(size)
                let end = try exact(2)
                guard end == Data([13, 10]) else { throw CustomsBackendError.message("chunk 缺少 CRLF") }
                try output.write(end)
            }
        }
    }
}
