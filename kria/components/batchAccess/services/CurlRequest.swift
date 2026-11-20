import Foundation

struct RequestField: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var isEnabled = true
    var key = ""
    var value = ""
    var hasEquals = true
    var originalEncodedKey: String?
    var originalEncodedValue: String?
    var formOption = "--form-string"
    var isFormEncoded = false
    var suppressesAutomaticHeader = false

    var queryComponent: String {
        let name = encode(key, original: originalEncodedKey)
        let content = encode(value, original: originalEncodedValue)
        return hasEquals || !value.isEmpty ? "\(name)=\(content)" : name
    }

    private func encode(_ text: String, original: String?) -> String {
        if let original {
            let decoded = isFormEncoded ? original.replacingOccurrences(of: "+", with: " ") : original
            if decoded.removingPercentEncoding == text { return original }
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

enum RequestBodyMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, raw, urlEncoded, multipart
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "无 Body"
        case .raw: "Raw"
        case .urlEncoded: "x-www-form-urlencoded"
        case .multipart: "form-data"
        }
    }
}

struct CurlRequest: Equatable, Codable, Sendable {
    var method = "GET"
    var usesCustomMethod = false
    var baseURL = ""
    var query: [RequestField] = []
    var headers: [RequestField] = []
    var bodyMode: RequestBodyMode = .none
    var body = ""
    var bodyFields: [RequestField] = []
    var followsRedirects = false
    var compressed = false
    var allowsInsecureTLS = false
    var extraArguments: [String] = []

    var url: String {
        guard var components = URLComponents(string: baseURL) else { return baseURL }
        let enabled = query.filter { $0.isEnabled && (!$0.key.isEmpty || $0.originalEncodedKey != nil || !$0.value.isEmpty) }
        components.percentEncodedQuery = enabled.isEmpty ? nil : enabled.map(\.queryComponent).joined(separator: "&")
        return components.string ?? baseURL
    }

    mutating func setURL(_ value: String) {
        guard var components = URLComponents(string: value) else {
            baseURL = value
            query = []
            return
        }
        let parsed = Self.parseQuery(components.percentEncodedQuery ?? "")
        // Keep disabled rows when editing the URL directly.
        query = parsed + query.filter { !$0.isEnabled }
        components.percentEncodedQuery = nil
        baseURL = components.string ?? value
    }

    static func parseQuery(_ value: String, formEncoded: Bool = false) -> [RequestField] {
        guard !value.isEmpty else { return [] }
        return value.split(separator: "&", omittingEmptySubsequences: false).map { component in
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pair[0])
            let value = pair.count > 1 ? String(pair[1]) : ""
            return RequestField(
                key: (formEncoded ? key.replacingOccurrences(of: "+", with: " ") : key).removingPercentEncoding ?? key,
                value: (formEncoded ? value.replacingOccurrences(of: "+", with: " ") : value).removingPercentEncoding ?? value,
                hasEquals: pair.count > 1,
                originalEncodedKey: key,
                originalEncodedValue: value,
                isFormEncoded: formEncoded
            )
        }
    }

    func validate() throws {
        guard !arguments.contains(where: { $0.contains("\0") }) else {
            throw CurlParseError.message("请求字段不能包含 NUL 字符")
        }
        guard let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty else {
            throw CurlParseError.message("请输入完整的 HTTP / HTTPS URL")
        }
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !method.isEmpty, method.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else {
            throw CurlParseError.message("请求方法必须是有效的 HTTP 方法")
        }
        if method.uppercased() == "HEAD", bodyMode != .none {
            throw CurlParseError.message("HEAD 请求不支持 Body，请切换方法或选择无 Body")
        }
        for field in headers where field.isEnabled && !field.key.isEmpty {
            guard field.key.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                  !field.value.contains("\r"), !field.value.contains("\n") else {
                throw CurlParseError.message("Header 名称不合法或值中包含换行")
            }
        }
        if bodyMode == .multipart {
            for field in bodyFields where field.isEnabled && !field.key.isEmpty {
                guard !field.key.contains("="),
                      field.formOption != "--form" || (!field.value.hasPrefix("@") && !field.value.hasPrefix("<")) else {
                    throw CurlParseError.message("暂不支持 form-data 文件读取，请使用文本字段")
                }
            }
        }
    }

    var arguments: [String] {
        var result = ["--url", url]
        let inferredMethod = bodyMode == .none ? "GET" : "POST"
        if method.uppercased() == "HEAD" {
            result.append("--head")
        } else if usesCustomMethod || method != inferredMethod {
            result += ["--request", method]
        }
        for field in headers where field.isEnabled && !field.key.isEmpty {
            // curl uses a semicolon to send an explicitly empty header value.
            let emptyHeader = field.suppressesAutomaticHeader ? "\(field.key):" : "\(field.key);"
            result += ["--header", field.value.isEmpty ? emptyHeader : "\(field.key): \(field.value)"]
        }
        switch bodyMode {
        case .none: break
        case .raw:
            // --data-raw never interprets an initial @ as a local file path.
            result += ["--data-raw", body]
        case .urlEncoded:
            let content = bodyFields.filter { $0.isEnabled && (!$0.key.isEmpty || $0.originalEncodedKey != nil || !$0.value.isEmpty) }.map(\.queryComponent).joined(separator: "&")
            result += ["--data-raw", content]
        case .multipart:
            for field in bodyFields where field.isEnabled && !field.key.isEmpty {
                result += [field.formOption, "\(field.key)=\(field.value)"]
            }
        }
        if followsRedirects { result.append("--location") }
        if compressed { result.append("--compressed") }
        if allowsInsecureTLS { result.append("--insecure") }
        result += extraArguments
        return result
    }

    var curl: String {
        let args = arguments
        var lines = ["curl"]
        var index = 0
        while index < args.count {
            let option = args[index]
            if index + 1 < args.count && !["--head", "--location", "--compressed", "--insecure", "--fail", "--fail-with-body", "--http1.1", "--http2", "--http2-prior-knowledge", "--globoff", "--path-as-is"].contains(option) {
                lines.append("  \(option) \(Self.quote(args[index + 1]))")
                index += 2
            } else {
                lines.append("  \(option)")
                index += 1
            }
        }
        return lines.joined(separator: " \\\n")
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CurlParseError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

enum CurlRequestParser {
    static func parse(_ command: String) throws -> CurlRequest {
        let tokens = try tokenize(command)
        guard tokens.first == "curl" || tokens.first == "/usr/bin/curl" else {
            throw CurlParseError.message("请输入以 curl 开头的单条请求命令")
        }
        var request = CurlRequest()
        var url: String?
        var explicitMethod: String?
        var head = false
        var get = false
        var rawParts: [String] = []
        var json = false
        var urlEncoded = false
        var index = 1
        let flags: Set<String> = ["--fail", "--fail-with-body", "--http1.1", "--http2", "--http2-prior-knowledge", "--globoff", "--path-as-is"]
        let valueOptions: Set<String> = ["--connect-timeout", "--max-time", "--retry", "--retry-delay", "--retry-max-time", "--proxy", "--noproxy", "--user", "--oauth2-bearer"]
        let aliases = ["-X": "--request", "-H": "--header", "-d": "--data", "-F": "--form", "-b": "--cookie", "-u": "--user", "-A": "--user-agent", "-e": "--referer", "-x": "--proxy", "-m": "--max-time"]

        while index < tokens.count {
            let token = tokens[index]
            index += 1
            var option = token
            var inlineValue: String?
            if token.hasPrefix("--"), let equal = token.firstIndex(of: "=") {
                option = String(token[..<equal])
                inlineValue = String(token[token.index(after: equal)...])
            } else if token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 2 {
                let short = String(token.prefix(2))
                if aliases[short] != nil {
                    option = short
                    inlineValue = String(token.dropFirst(2))
                } else if token.dropFirst().allSatisfy({ "sSvLikIg".contains($0) }) {
                    for flag in token.dropFirst() {
                        switch flag {
                        case "L": request.followsRedirects = true
                        case "k": request.allowsInsecureTLS = true
                        case "I": head = true
                        case "g": request.extraArguments.append("--globoff")
                        default: break
                        }
                    }
                    continue
                }
            }
            option = aliases[option] ?? option
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard index < tokens.count else { throw CurlParseError.message("\(option) 缺少参数") }
                let result = tokens[index]
                index += 1
                return result
            }
            let noValueOptions: Set<String> = ["-G", "--get", "-I", "--head", "-L", "--location", "--compressed", "-k", "--insecure", "-g", "-s", "-S", "-v", "-i", "--silent", "--show-error", "--verbose", "--include", "--no-progress-meter"]
            if inlineValue != nil, noValueOptions.contains(option) {
                throw CurlParseError.message("\(option) 不接受附加值")
            }
            switch option {
            case "--url":
                guard url == nil else { throw CurlParseError.message("一次只能导入一条 URL 请求") }
                url = try value()
            case "--request": explicitMethod = try value()
            case "--header":
                let header = try value()
                guard !header.hasPrefix("@") else { throw CurlParseError.message("不支持从文件读取 Headers") }
                if let colon = header.firstIndex(of: ":") {
                    let key = String(header[..<colon]).trimmingCharacters(in: .whitespaces)
                    let content = String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if content.isEmpty {
                        request.headers.append(RequestField(key: key, suppressesAutomaticHeader: true))
                    } else {
                        request.headers.append(RequestField(key: key, value: content))
                    }
                } else if header.hasSuffix(";") {
                    request.headers.append(RequestField(key: String(header.dropLast())))
                } else {
                    throw CurlParseError.message("Header 格式应为 Name: Value")
                }
            case "--data", "--data-ascii", "--data-binary", "--data-raw", "--json":
                let data = try value()
                guard option == "--data-raw" || !data.hasPrefix("@") else {
                    throw CurlParseError.message("不支持从本地文件读取 Body，请粘贴文本内容")
                }
                guard request.bodyMode != .multipart else { throw CurlParseError.message("不能混用 Raw 和 form-data") }
                request.bodyMode = .raw
                if option == "--json", !rawParts.isEmpty {
                    rawParts[rawParts.count - 1] += data
                } else { rawParts.append(data) }
                json = json || option == "--json"
            case "--data-urlencode":
                urlEncoded = true
                let data = try value()
                guard !data.hasPrefix("@"), !(data.contains("@") && !data.contains("=")) else {
                    throw CurlParseError.message("不支持 --data-urlencode 文件读取")
                }
                guard request.bodyMode != .multipart else { throw CurlParseError.message("不能混用表单和 Raw Body") }
                request.bodyMode = .raw
                let parts = data.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                let content = String(parts.count > 1 ? parts[1] : parts[0])
                let encoded = content.addingPercentEncoding(withAllowedCharacters: allowed) ?? content
                rawParts.append(parts.count > 1 && !parts[0].isEmpty ? "\(parts[0])=\(encoded)" : encoded)
            case "--form", "--form-string":
                guard rawParts.isEmpty else { throw CurlParseError.message("不能混用 Raw 和 form-data") }
                let data = try value()
                guard let equal = data.firstIndex(of: "=") else { throw CurlParseError.message("form-data 格式应为 name=value") }
                let content = String(data[data.index(after: equal)...])
                guard option != "--form" || (!content.hasPrefix("@") && !content.hasPrefix("<")) else {
                    throw CurlParseError.message("暂不支持 form-data 文件上传，请使用文本字段")
                }
                request.bodyMode = .multipart
                request.bodyFields.append(RequestField(key: String(data[..<equal]), value: content, formOption: option))
            case "--cookie":
                let cookie = try value()
                guard cookie.contains("=") else { throw CurlParseError.message("Cookie 需要 name=value 文本，不支持 Cookie 文件") }
                request.headers.append(RequestField(key: "Cookie", value: cookie))
            case "--user-agent", "--referer":
                // Preserve curl's override rules and Referer's ;auto semantics.
                request.extraArguments += [option, try value()]
            case "-G", "--get": get = true
            case "-I", "--head": head = true
            case "-L", "--location": request.followsRedirects = true
            case "--compressed": request.compressed = true
            case "-k", "--insecure": request.allowsInsecureTLS = true
            case "-g": request.extraArguments.append("--globoff")
            case "-s", "-S", "-v", "-i", "--silent", "--show-error", "--verbose", "--include", "--no-progress-meter": break
            default:
                if flags.contains(option), inlineValue == nil {
                    request.extraArguments.append(option)
                } else if valueOptions.contains(option) {
                    request.extraArguments += [option, try value()]
                } else if token.hasPrefix("-") {
                    throw CurlParseError.message("暂不支持参数 \(option)，请移除后再导入（不会静默丢弃）")
                } else {
                    guard url == nil else { throw CurlParseError.message("一次只能导入一条 URL 请求") }
                    url = token
                }
            }
        }
        guard let url else { throw CurlParseError.message("cURL 中缺少 URL") }
        request.setURL(url)
        request.body = rawParts.joined(separator: "&")
        if get, !rawParts.isEmpty {
            request.query += CurlRequest.parseQuery(request.body)
            request.body = ""
            request.bodyMode = .none
        }
        if get, request.bodyMode == .multipart { throw CurlParseError.message("不支持同时使用 --get 和 form-data") }
        request.method = explicitMethod ?? (head ? "HEAD" : (get || request.bodyMode == .none ? "GET" : "POST"))
        request.usesCustomMethod = explicitMethod != nil
        if head, explicitMethod != nil, request.method.uppercased() != "HEAD" {
            throw CurlParseError.message("--head 与自定义请求方法冲突，请使用 HEAD 方法")
        }
        if json {
            for (key, value) in [("Content-Type", "application/json"), ("Accept", "application/json")] {
                if !request.headers.contains(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
                   !request.extraArguments.contains(where: { $0.lowercased().hasPrefix(key.lowercased() + ":") }) {
                    request.headers.append(RequestField(key: key, value: value))
                }
            }
        }
        if request.bodyMode == .raw, !json,
           urlEncoded || request.headers.contains(where: { $0.key.lowercased() == "content-type" && $0.value.lowercased().hasPrefix("application/x-www-form-urlencoded") }) {
            request.bodyMode = .urlEncoded
            request.bodyFields = CurlRequest.parseQuery(request.body, formEncoded: true)
        }
        try request.validate()
        return request
    }

    // A shell-like lexer, not a shell evaluator: quotes and line continuations are supported;
    // operators, variable expansion and command substitution are never executed.
    static func tokenize(_ command: String) throws -> [String] {
        guard !command.contains("\0") else { throw CurlParseError.message("请求命令不能包含 NUL 字符") }
        let chars = Array(command)
        var tokens: [String] = []
        var token = ""
        var started = false
        var quote: Character?
        var index = 0
        while index < chars.count {
            let char = chars[index]
            index += 1
            if quote == "'" {
                if char == "'" { quote = nil } else { token.append(char) }
                continue
            }
            if char == "\\" {
                guard index < chars.count else { throw CurlParseError.message("命令末尾的转义符尚未完成") }
                // CRLF is a single Swift Character. Accept all newline forms;
                // copied rich text may also insert whitespace before a continuation.
                if quote == nil {
                    var continuation = index
                    while continuation < chars.count, chars[continuation].isWhitespace,
                          !chars[continuation].isNewline {
                        continuation += 1
                    }
                    if continuation < chars.count, chars[continuation].isNewline {
                        index = continuation + 1
                        continue
                    }
                }
                let next = chars[index]
                if quote == "\"", !next.isNewline, !["$", "`", "\"", "\\"].contains(next) {
                    token.append(char)
                    continue
                }
                index += 1
                if !next.isNewline { token.append(next); started = true }
                continue
            }
            if quote == "\"" {
                if char == "\"" { quote = nil }
                else if char == "$" || char == "`" { throw CurlParseError.message("不支持 Shell 变量或命令替换，请粘贴实际值") }
                else { token.append(char) }
                continue
            }
            if char == "'" || char == "\"" { quote = char; started = true; continue }
            if char.isWhitespace {
                if started { tokens.append(token); token = ""; started = false }
                continue
            }
            if ";&|<>`$()".contains(char) { throw CurlParseError.message("URL 或参数中的特殊字符需要引号；不支持 Shell 运算符") }
            token.append(char)
            started = true
        }
        guard quote == nil else { throw CurlParseError.message("引号尚未闭合，完成编辑后会自动同步") }
        if started { tokens.append(token) }
        return tokens
    }
}

struct BatchAccessRecord: Identifiable, Sendable {
    let id: UUID
    let sequence: Int
    let startedAt: Date
    var finishedAt: Date?
    var result = "请求中…"
    var responseHeaders = ""
    var httpStatus: Int?
    var isFailure = false
    var duration: TimeInterval = 0
    var byteCount = 0
}

enum BatchDispatchMode: String, CaseIterable, Identifiable {
    case pulse, randomWithinSecond
    var id: Self { self }
    var title: String { self == .pulse ? "脉冲" : "每秒内随机" }
}

enum JSONResponseFormatter {
    static func format(_ response: String) -> String {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: pretty, encoding: .utf8) else { return response }
        return text
    }
}
