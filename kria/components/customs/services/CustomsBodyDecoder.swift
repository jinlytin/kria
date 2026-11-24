import Foundation
import zlib

/// Presentation only. Never replaces the captured wire body or its headers.
nonisolated enum CustomsBodyDecoder {
    static let outputLimit = 512 * 1024

    struct Output: Sendable {
        let data: Data
        let decodedEncodings: [String]
    }

    enum Failure: Error, Sendable, LocalizedError {
        case unsupported(String)
        case truncated
        case outputTooLarge
        case invalidStream
        case initialization

        var errorDescription: String? {
            switch self {
            case .unsupported(let encoding): return "不支持 Content-Encoding: \(encoding)（br / Brotli 暂不支持）"
            case .truncated: return "压缩正文不完整或已截断，无法验证完整解压结果"
            case .outputTooLarge: return "解压输出超过 512 KiB 安全上限，已停止解压"
            case .invalidStream: return "压缩数据损坏、校验失败或包含无效尾部数据"
            case .initialization: return "系统 zlib 解码器初始化失败"
            }
        }
    }

    /// Decodes stacked content encodings in reverse order, with a limit at every stage.
    /// HTTP deflate supports both the standard zlib wrapper and legacy raw deflate.
    static func decode(data: Data, contentEncoding: String, truncated: Bool) throws -> Output {
        let encodings = contentEncoding.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        guard !encodings.isEmpty else { return Output(data: Data(data.prefix(outputLimit)), decodedEncodings: []) }
        guard encodings.count <= 4 else { throw Failure.unsupported(contentEncoding) }
        for encoding in encodings where !["gzip", "x-gzip", "deflate"].contains(encoding) {
            throw Failure.unsupported(encoding)
        }
        guard !truncated, data.count <= outputLimit else { throw Failure.truncated }
        var bytes = data
        for encoding in encodings.reversed() {
            try Task.checkCancellation()
            if encoding == "deflate" {
                do {
                    bytes = try inflateData(bytes, windowBits: 15, concatenatedGzip: false)
                } catch Failure.invalidStream {
                    // Some HTTP servers send raw DEFLATE instead of RFC 1950 wrapped data.
                    bytes = try inflateData(bytes, windowBits: -15, concatenatedGzip: false)
                }
            } else {
                bytes = try inflateData(bytes, windowBits: 15 + 16, concatenatedGzip: true)
            }
        }
        return Output(data: bytes, decodedEncodings: encodings)
    }

    private static func inflateData(_ input: Data, windowBits: Int32, concatenatedGzip: Bool) throws -> Data {
        guard !input.isEmpty else { throw Failure.truncated }
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw Failure.initialization }
        defer { inflateEnd(&stream) }
        var output = Data()
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        return try input.withUnsafeBytes { rawInput in
            guard let base = rawInput.bindMemory(to: Bytef.self).baseAddress else { throw Failure.truncated }
            // zlib's API uses mutable pointers but does not mutate input.
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            while true {
                try Task.checkCancellation()
                let availableBefore = stream.avail_in
                // A one-byte probe distinguishes exactly-at-limit from over-limit output.
                let capacity = min(scratch.count, outputLimit - output.count + 1)
                let status: Int32 = scratch.withUnsafeMutableBytes { rawOutput in
                    stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = capacity - Int(stream.avail_out)
                guard produced <= outputLimit - output.count else { throw Failure.outputTooLarge }
                output.append(contentsOf: scratch.prefix(produced))
                if status == Z_STREAM_END {
                    if stream.avail_in == 0 { return output }
                    guard concatenatedGzip else { throw Failure.invalidStream }
                    // RFC 1952 permits concatenated gzip members; the aggregate is bounded.
                    let nextInput = stream.next_in
                    let remainingInput = stream.avail_in
                    guard inflateReset2(&stream, windowBits) == Z_OK else { throw Failure.initialization }
                    stream.next_in = nextInput
                    stream.avail_in = remainingInput
                    continue
                }
                if status == Z_DATA_ERROR || status == Z_NEED_DICT { throw Failure.invalidStream }
                guard status == Z_OK || status == Z_BUF_ERROR else { throw Failure.invalidStream }
                if produced == 0 && stream.avail_in == availableBefore {
                    throw stream.avail_in == 0 ? Failure.truncated : Failure.invalidStream
                }
            }
        }
    }
}
