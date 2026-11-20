struct JSONResponseDocument: Sendable {
    let root: JSONResponseNode

    static func parse(_ text: String) -> JSONResponseDocument? {
        var parser = JSONResponseParser(text)
        guard let root = parser.parse() else { return nil }
        return JSONResponseDocument(root: root)
    }

    func rows(collapsedNodeIDs: Set<Int>) -> [JSONResponseRow] {
        var result: [JSONResponseRow] = []
        var pending: [(node: JSONResponseNode, depth: Int, hasComma: Bool, isClosing: Bool)] = [
            (root, 0, false, false)
        ]

        while let entry = pending.popLast() {
            let node = entry.node
            let isObject = node.kind == .object
            let isContainer = isObject || node.kind == .array
            let isCollapsed = node.isExpandable && collapsedNodeIDs.contains(node.id)
            let value: String
            if entry.isClosing {
                value = isObject ? "}" : "]"
            } else if isContainer {
                if !node.isExpandable {
                    value = isObject ? "{}" : "[]"
                } else if isCollapsed {
                    value = isObject ? "{ … }" : "[ … ]"
                } else {
                    value = isObject ? "{" : "["
                }
            } else {
                value = node.rawValue
            }

            let isOpening = node.isExpandable && !isCollapsed && !entry.isClosing
            result.append(JSONResponseRow(
                nodeID: node.id,
                depth: entry.depth,
                key: entry.isClosing ? nil : node.key,
                value: value,
                kind: node.kind,
                isExpandable: node.isExpandable,
                isCollapsed: isCollapsed,
                isClosing: entry.isClosing,
                hasComma: isOpening ? false : entry.hasComma,
                childCount: node.children.count
            ))

            if isOpening {
                pending.append((node, entry.depth, entry.hasComma, true))
                for index in node.children.indices.reversed() {
                    pending.append((
                        node.children[index], entry.depth + 1,
                        index < node.children.count - 1, false
                    ))
                }
            }
        }
        return result
    }

    var expandableNodeIDs: Set<Int> {
        var result: Set<Int> = []
        var pending = [root]
        while let node = pending.popLast() {
            if node.isExpandable {
                result.insert(node.id)
                pending.append(contentsOf: node.children)
            }
        }
        return result
    }
}

struct JSONResponseNode: Identifiable, Sendable {
    let id: Int
    // Includes the original quotation marks and escape sequences.
    let key: String?
    let kind: JSONResponseKind
    // Array uses shared copy-on-write storage; containers retain a range, not
    // an additional copy of the complete subtree at every nesting level.
    fileprivate let source: [UInt8]
    fileprivate let sourceRange: Range<Int>
    let children: [JSONResponseNode]

    var rawValue: String { String(decoding: source[sourceRange], as: UTF8.self) }

    var isExpandable: Bool {
        (kind == .object || kind == .array) && !children.isEmpty
    }
}

enum JSONResponseKind: Sendable {
    case object, array, string, number, bool, null
}

struct JSONResponseRow: Equatable, Sendable {
    let nodeID: Int
    let depth: Int
    let key: String?
    let value: String
    let kind: JSONResponseKind
    let isExpandable: Bool
    let isCollapsed: Bool
    let isClosing: Bool
    let hasComma: Bool
    let childCount: Int
}

private struct JSONResponseParser {
    // Root depth is zero; keys are metadata, not additional nodes.
    private static let maximumDepth = 128
    private static let maximumNodeCount = 20_000

    private let bytes: [UInt8]
    private var position = 0
    private var nodeCount = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    mutating func parse() -> JSONResponseNode? {
        skipWhitespace()
        guard let root = parseNode(key: nil, depth: 0) else { return nil }
        skipWhitespace()
        return position == bytes.count ? root : nil
    }

    private mutating func parseNode(key: String?, depth: Int) -> JSONResponseNode? {
        guard depth <= Self.maximumDepth,
              nodeCount < Self.maximumNodeCount,
              position < bytes.count else { return nil }

        let id = nodeCount
        nodeCount += 1
        let start = position
        let kind: JSONResponseKind
        var children: [JSONResponseNode] = []

        switch bytes[position] {
        case 0x7B, 0x5B: // { [
            let isObject = bytes[position] == 0x7B
            kind = isObject ? .object : .array
            let closing: UInt8 = isObject ? 0x7D : 0x5D
            position += 1
            skipWhitespace()
            if !consume(closing) {
                while true {
                    var childKey: String?
                    if isObject {
                        let keyStart = position
                        guard scanString() else { return nil }
                        childKey = lexeme(from: keyStart)
                        skipWhitespace()
                        guard consume(0x3A) else { return nil } // :
                        skipWhitespace()
                    }
                    guard let child = parseNode(key: childKey, depth: depth + 1) else {
                        return nil
                    }
                    children.append(child)
                    skipWhitespace()
                    if consume(closing) { break }
                    guard consume(0x2C) else { return nil } // ,
                    skipWhitespace()
                    // A closing delimiter here is rejected by the next key/value scan.
                }
            }
        case 0x22:
            kind = .string
            guard scanString() else { return nil }
        case 0x2D, 0x30...0x39:
            kind = .number
            guard scanNumber() else { return nil }
        case 0x74:
            kind = .bool
            guard consumeLiteral("true") else { return nil }
        case 0x66:
            kind = .bool
            guard consumeLiteral("false") else { return nil }
        case 0x6E:
            kind = .null
            guard consumeLiteral("null") else { return nil }
        default:
            return nil
        }

        return JSONResponseNode(
            id: id, key: key, kind: kind,
            source: bytes, sourceRange: start..<position, children: children
        )
    }

    private mutating func scanString() -> Bool {
        guard consume(0x22) else { return false }
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            switch byte {
            case 0x22:
                return true
            case 0x00...0x1F:
                return false
            case 0x5C: // backslash
                guard position < bytes.count else { return false }
                let escape = bytes[position]
                position += 1
                switch escape {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    break
                case 0x75: // u followed by exactly four hexadecimal digits
                    guard bytes.count - position >= 4 else { return false }
                    for _ in 0..<4 {
                        switch bytes[position] {
                        case 0x30...0x39, 0x41...0x46, 0x61...0x66:
                            position += 1
                        default:
                            return false
                        }
                    }
                default:
                    return false
                }
            default:
                // Swift String supplies valid UTF-8. Non-ASCII bytes cannot be
                // mistaken for ASCII quotes, backslashes or control characters.
                break
            }
        }
        return false
    }

    private mutating func scanNumber() -> Bool {
        _ = consume(0x2D) // optional minus
        if !consume(0x30) {
            guard position < bytes.count,
                  (0x31...0x39).contains(bytes[position]) else { return false }
            position += 1
            scanDigits()
        }
        if consume(0x2E) { // fractional part requires at least one digit
            let start = position
            scanDigits()
            guard position > start else { return false }
        }
        if consume(0x65) || consume(0x45) {
            if !consume(0x2B) { _ = consume(0x2D) }
            let start = position
            scanDigits()
            guard position > start else { return false }
        }
        // Invalid suffixes (including leading-zero continuations) are rejected
        // by the enclosing delimiter check or the final end-of-input check.
        return true
    }

    private mutating func scanDigits() {
        while position < bytes.count, (0x30...0x39).contains(bytes[position]) {
            position += 1
        }
    }

    private mutating func consumeLiteral(_ literal: StaticString) -> Bool {
        literal.withUTF8Buffer { expected in
            guard bytes.count - position >= expected.count else { return false }
            for byte in expected {
                guard bytes[position] == byte else { return false }
                position += 1
            }
            return true
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    private mutating func skipWhitespace() {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D:
                position += 1
            default:
                return
            }
        }
    }

    private func lexeme(from start: Int) -> String {
        String(decoding: bytes[start..<position], as: UTF8.self)
    }
}
