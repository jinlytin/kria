import Foundation
import Darwin
import XCTest
import zlib
@testable import kria

nonisolated final class CustomsPresentationTests: XCTestCase {
    private enum FixtureError: Error {
        case compression(Int32)
    }

    /// Produce actual RFC 1952 / RFC 1950 / raw DEFLATE bytes entirely in memory.
    private func compressed(_ input: Data, windowBits: Int32 = 31) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                       windowBits, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw FixtureError.compression(initialized) }
        defer { deflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))))
        let status = input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            return buffer.withUnsafeMutableBytes { destination in
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0 else {
            throw FixtureError.compression(status)
        }
        return Data(buffer.prefix(Int(stream.total_out)))
    }

    private func assertDecodeFailure(_ input: Data, encoding: String = "gzip",
                                     truncated: Bool = false, expected: CustomsBodyDecoder.Failure,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CustomsBodyDecoder.decode(data: input, contentEncoding: encoding,
                                                          truncated: truncated), file: file, line: line) { error in
            guard let actual = error as? CustomsBodyDecoder.Failure else {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
                return
            }
            switch (actual, expected) {
            case (.unsupported(let actualEncoding), .unsupported(let expectedEncoding)):
                XCTAssertEqual(actualEncoding, expectedEncoding, file: file, line: line)
            case (.truncated, .truncated), (.outputTooLarge, .outputTooLarge),
                 (.invalidStream, .invalidStream), (.initialization, .initialization):
                break
            default:
                XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
            }
        }
    }

    func testGzipDecodesWithoutChangingWireBytes() throws {
        let body = Data("中文 gzip body\n".utf8)
        let wire = try compressed(body)
        let originalWire = wire
        XCTAssertEqual(Array(wire.prefix(2)), [0x1f, 0x8b])
        let output = try CustomsBodyDecoder.decode(data: wire, contentEncoding: "gzip", truncated: false)
        XCTAssertEqual(output.data, body)
        XCTAssertEqual(output.decodedEncodings, ["gzip"])
        XCTAssertEqual(wire, originalWire)
    }

    func testConcatenatedGzipDecodesAllMembers() throws {
        let first = Data("first".utf8), second = Data("第二段".utf8)
        let wire = try compressed(first) + compressed(second)
        let output = try CustomsBodyDecoder.decode(data: wire, contentEncoding: "gzip", truncated: false)
        XCTAssertEqual(output.data, first + second)
        XCTAssertEqual(output.decodedEncodings, ["gzip"])
    }

    func testEmptyGzipMemberDecodes() throws {
        let output = try CustomsBodyDecoder.decode(data: compressed(Data()), contentEncoding: "gzip", truncated: false)
        XCTAssertTrue(output.data.isEmpty)
        XCTAssertEqual(output.decodedEncodings, ["gzip"])
    }

    func testWrappedDeflateDecodes() throws {
        let body = Data("zlib wrapped body".utf8)
        let output = try CustomsBodyDecoder.decode(data: compressed(body, windowBits: 15),
                                                  contentEncoding: "deflate", truncated: false)
        XCTAssertEqual(output.data, body)
        XCTAssertEqual(output.decodedEncodings, ["deflate"])
    }

    func testRawDeflateDecodes() throws {
        let body = Data("legacy raw deflate".utf8)
        let output = try CustomsBodyDecoder.decode(data: compressed(body, windowBits: -15),
                                                  contentEncoding: "deflate", truncated: false)
        XCTAssertEqual(output.data, body)
        XCTAssertEqual(output.decodedEncodings, ["deflate"])
    }

    func testEncodingStackDecodesInReverseOrder() throws {
        let body = Data("stack order matters".utf8)
        let wire = try compressed(compressed(body), windowBits: 15)
        let output = try CustomsBodyDecoder.decode(data: wire, contentEncoding: " GZip, identity, DeFlAtE ", truncated: false)
        XCTAssertEqual(output.data, body)
        XCTAssertEqual(output.decodedEncodings, ["gzip", "deflate"])
    }

    func testXGzipAliasDecodes() throws {
        let body = Data("alias".utf8)
        let output = try CustomsBodyDecoder.decode(data: compressed(body), contentEncoding: " X-GZip ", truncated: false)
        XCTAssertEqual(output.data, body)
        XCTAssertEqual(output.decodedEncodings, ["x-gzip"])
    }

    func testExactly512KiBOutputIsAccepted() throws {
        XCTAssertEqual(CustomsBodyDecoder.outputLimit, 512 * 1024)
        let body = Data(repeating: 0x61, count: 512 * 1024)
        for bits: Int32 in [31, 15, -15] {
            let output = try CustomsBodyDecoder.decode(data: compressed(body, windowBits: bits),
                                                      contentEncoding: bits == 31 ? "gzip" : "deflate", truncated: false)
            XCTAssertEqual(output.data, body, "windowBits=\(bits)")
        }
    }

    func testOneByteOver512KiBOutputIsRejected() throws {
        let body = Data(repeating: 0x61, count: 512 * 1024 + 1)
        for bits: Int32 in [31, 15, -15] {
            assertDecodeFailure(try compressed(body, windowBits: bits),
                                encoding: bits == 31 ? "gzip" : "deflate", expected: .outputTooLarge)
        }
    }

    func testConcatenatedGzipAggregateLimit() throws {
        let half = Data(repeating: 0x62, count: 256 * 1024)
        let wire = try compressed(half) + compressed(half)
        XCTAssertEqual(try CustomsBodyDecoder.decode(data: wire, contentEncoding: "gzip", truncated: false).data, half + half)
        assertDecodeFailure(try wire + compressed(Data([0x63])), expected: .outputTooLarge)
    }

    func testStackRejectsOversizedIntermediateOutput() throws {
        // The outer gzip expands past the budget, even though the inner stream is invalid.
        let wire = try compressed(Data(repeating: 0, count: 512 * 1024 + 1))
        assertDecodeFailure(wire, encoding: "deflate, gzip", expected: .outputTooLarge)
    }

    func testBadGzipCRCIsRejected() throws {
        var wire = try compressed(Data("CRC validation".utf8))
        wire[wire.count - 8] ^= 0x01
        assertDecodeFailure(wire, expected: .invalidStream)
    }

    func testBadGzipSizeTrailerIsRejected() throws {
        var wire = try compressed(Data("size validation".utf8))
        wire[wire.count - 4] ^= 0x01
        assertDecodeFailure(wire, expected: .invalidStream)
    }

    func testMissingGzipTrailerIsTruncated() throws {
        let wire = try compressed(Data("missing trailer".utf8))
        assertDecodeFailure(Data(wire.dropLast(8)), expected: .truncated)
    }

    func testExtraGzipTrailingGarbageIsRejected() throws {
        let wire = try compressed(Data("extra trailer".utf8))
        assertDecodeFailure(wire + Data([0xff, 0xff, 0xff]), expected: .invalidStream)
    }

    func testTruncatedSecondGzipMemberIsRejected() throws {
        let first = try compressed(Data("complete member".utf8))
        let second = try compressed(Data("incomplete member".utf8))
        assertDecodeFailure(first + Data(second.dropLast(8)), expected: .truncated)
    }

    func testUnknownEncodingIsRejected() {
        assertDecodeFailure(Data([1, 2]), encoding: " Zstd ", expected: .unsupported("zstd"))
    }

    func testBrotliIsRejectedEvenInsideStack() throws {
        assertDecodeFailure(try compressed(Data("not brotli".utf8)), encoding: "br, gzip", expected: .unsupported("br"))
    }

    func testTooManyEncodingLayersAreRejected() throws {
        let encoding = "gzip,gzip,gzip,gzip,gzip"
        assertDecodeFailure(try compressed(Data([1])), encoding: encoding, expected: .unsupported(encoding))
    }

    func testCaptureTruncatedFlagRejectsOtherwiseValidStreams() throws {
        for bits: Int32 in [31, 15, -15] {
            assertDecodeFailure(try compressed(Data("complete wire bytes".utf8), windowBits: bits),
                                encoding: bits == 31 ? "gzip" : "deflate", truncated: true, expected: .truncated)
        }
    }

    func testEmptyCompressedInputIsTruncated() {
        for encoding in ["gzip", "deflate"] {
            assertDecodeFailure(Data(), encoding: encoding, expected: .truncated)
        }
    }

    func testOversizedCapturedInputIsRejectedBeforeInflating() {
        assertDecodeFailure(Data(repeating: 0, count: 512 * 1024 + 1), expected: .truncated)
    }

    func testIdentityPresentationRemainsBoundedWithTruncatedFlag() throws {
        let body = Data(repeating: 0x64, count: 512 * 1024 + 1)
        let output = try CustomsBodyDecoder.decode(data: body, contentEncoding: " identity, ", truncated: true)
        XCTAssertEqual(output.data, Data(body.prefix(512 * 1024)))
        XCTAssertTrue(output.decodedEncodings.isEmpty)
    }

    private func completedTransaction(body: Data = Data()) -> CustomsTransaction {
        var transaction = CustomsTransaction(method: "POST", url: "https://example.test/a%2Fb?q=%FF")
        transaction.finishedAt = transaction.startedAt.addingTimeInterval(1)
        transaction.requestBody = body
        transaction.statusCode = 200
        return transaction
    }

    private func assertPipedBody(_ body: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let command = try XCTUnwrap(completedTransaction(body: body).curl(), file: file, line: line)
        XCTAssertTrue(command.hasPrefix("printf '%s' '\(body.base64EncodedString())' | /usr/bin/base64 -D | curl --disable"), file: file, line: line)
        XCTAssertTrue(command.hasSuffix("--data-binary @-"), file: file, line: line)
        XCTAssertFalse(command.contains("\0"), file: file, line: line)
    }

    func testCurlAtFilenameIsPipedRatherThanReadFromDisk() throws {
        let body = Data("@filename".utf8)
        try assertPipedBody(body)
        let command = try XCTUnwrap(completedTransaction(body: body).curl())
        XCTAssertFalse(command.contains("--data-binary '@filename'"))
    }

    func testCurlBinaryBodyIsPipedLosslessly() throws {
        try assertPipedBody(Data([0xff, 0x80, 0x27, 0x0a]))
    }

    func testCurlValidUTF8ContainingNULIsPiped() throws {
        let body = Data("before\0after".utf8)
        XCTAssertNotNil(String(data: body, encoding: .utf8))
        try assertPipedBody(body)
    }

    func testCurlQuotesMethodURLHeadersAndTextBody() throws {
        var transaction = completedTransaction(body: Data("中文 'body'\nline".utf8))
        transaction.method = "M'ETHOD"
        transaction.url = "https://example.test/o'brien?q='value'"
        transaction.requestHeaders = [CustomsHeader(name: "X-Quote", value: "it's 'safe'")]
        let command = try XCTUnwrap(transaction.curl())
        XCTAssertTrue(command.contains("-X 'M'\\''ETHOD'"))
        XCTAssertTrue(command.contains("'https://example.test/o'\\''brien?q='\\''value'\\'''"))
        XCTAssertTrue(command.contains("-H 'X-Quote: it'\\''s '\\''safe'\\'''"))
        XCTAssertTrue(command.contains("--data-binary '中文 '\\''body'\\''\nline'"))
        XCTAssertFalse(command.contains("base64"))
    }

    func testCurlDisablesConfigAndGlobbingAndPreservesRawPath() throws {
        var transaction = completedTransaction()
        transaction.url = "https://example.test/[a]/../b%2Fc?x={1,2}&q=%FF"
        let command = try XCTUnwrap(transaction.curl())
        XCTAssertTrue(command.hasPrefix("curl --disable --globoff --path-as-is -X 'POST' "))
        XCTAssertTrue(command.contains("'\(transaction.url)'"))
        XCTAssertFalse(command.contains("--data-binary"))
    }

    func testCurlFailedResponseCannotBeCopied() {
        var transaction = completedTransaction()
        transaction.error = "response read failed"
        XCTAssertFalse(transaction.canCopyCurl)
        XCTAssertNil(transaction.curl())
        XCTAssertNil(transaction.curl(original: true))
    }

    func testCurlIncompleteRequestCannotBeCopied() {
        var transaction = completedTransaction(body: Data("partial".utf8))
        transaction.requestBodyIncomplete = true
        XCTAssertFalse(transaction.canCopyCurl)
        XCTAssertNil(transaction.curl())
        XCTAssertNil(transaction.curl(original: true))
    }

    func testCurlTruncatedRequestCannotBeCopied() {
        var transaction = completedTransaction()
        transaction.requestBodyTruncated = true
        XCTAssertFalse(transaction.canCopyCurl)
        XCTAssertNil(transaction.curl())
    }

    func testCurlPendingRequestCannotBeCopied() {
        var transaction = completedTransaction()
        transaction.finishedAt = nil
        XCTAssertFalse(transaction.canCopyCurl)
        XCTAssertNil(transaction.curl())
    }

    func testCurlTunnelCannotBeCopied() {
        var transaction = completedTransaction()
        transaction.isTunnel = true
        XCTAssertFalse(transaction.canCopyCurl)
        XCTAssertNil(transaction.curl())
    }

    func testCurlAdditionalTransferCodingDisablesBothCopies() {
        for headers in [
            [CustomsHeader(name: "Transfer-Encoding", value: "gzip, chunked")],
            [CustomsHeader(name: "transfer-encoding", value: "gzip"), CustomsHeader(name: "TRANSFER-ENCODING", value: "chunked")],
            [CustomsHeader(name: "Transfer-Encoding", value: "deflate")]
        ] {
            var transaction = completedTransaction()
            transaction.requestHeaders = headers
            XCTAssertFalse(transaction.canCopyCurl)
            XCTAssertNil(transaction.curl())
            XCTAssertNil(transaction.curl(original: true))
        }
    }

    func testCurlChunkedAloneRemainsCopyableWithoutFramingHeaders() throws {
        var transaction = completedTransaction(body: Data("dechunked".utf8))
        transaction.requestHeaders = [
            CustomsHeader(name: "TRANSFER-ENCODING", value: " ChUnKeD "),
            CustomsHeader(name: "Content-Length", value: "999"),
            CustomsHeader(name: "Connection", value: "close")
        ]
        XCTAssertTrue(transaction.canCopyCurl)
        let command = try XCTUnwrap(transaction.curl())
        XCTAssertFalse(command.contains("-H "))
        XCTAssertTrue(command.hasSuffix("--data-binary 'dechunked'"))
    }

    func testCurlOriginalAndAfterHeadersCopiesDifferWithoutMutatingCapture() throws {
        var transaction = completedTransaction(body: Data("unchanged body".utf8))
        transaction.originalRequestHeaders = [CustomsHeader(name: "X-Rule", value: "old"),
                                              CustomsHeader(name: "Cookie", value: "a=1"),
                                              CustomsHeader(name: "Cookie", value: "b=2")]
        transaction.requestHeaders = [CustomsHeader(name: "X-Rule", value: "new"),
                                      CustomsHeader(name: "X-Added", value: "added"),
                                      CustomsHeader(name: "Cookie", value: "a=1"),
                                      CustomsHeader(name: "Cookie", value: "b=2")]
        let originals = transaction.originalRequestHeaders, afters = transaction.requestHeaders
        let original = try XCTUnwrap(transaction.curl(original: true))
        let after = try XCTUnwrap(transaction.curl())
        XCTAssertNotEqual(original, after)
        XCTAssertTrue(original.contains("-H 'X-Rule: old'"))
        XCTAssertFalse(original.contains("X-Added"))
        XCTAssertTrue(after.contains("-H 'X-Rule: new'"))
        XCTAssertTrue(after.contains("-H 'X-Added: added'"))
        for command in [original, after] {
            XCTAssertTrue(command.contains("-H 'Cookie: a=1'"))
            XCTAssertTrue(command.contains("-H 'Cookie: b=2'"))
            XCTAssertTrue(command.hasSuffix("--data-binary 'unchanged body'"))
        }
        XCTAssertEqual(transaction.originalRequestHeaders, originals)
        XCTAssertEqual(transaction.requestHeaders, afters)
        XCTAssertEqual(transaction.requestBody, Data("unchanged body".utf8))
    }

    func testCurlEmptyHeaderUsesSemicolonSyntax() throws {
        var transaction = completedTransaction()
        transaction.requestHeaders = [CustomsHeader(name: "X-Empty", value: "")]
        XCTAssertTrue(try XCTUnwrap(transaction.curl()).contains("-H 'X-Empty;'"))
    }

    func testCurlResponseCaptureTruncationDoesNotMakeRequestIncomplete() throws {
        var transaction = completedTransaction(body: Data("complete request".utf8))
        transaction.responseBodyTruncated = true
        XCTAssertTrue(transaction.canCopyCurl)
        XCTAssertNotNil(transaction.curl())
    }
}

nonisolated final class CustomsPresentationViewModelTests: XCTestCase {
    private struct StoredSettings: Decodable {
        let port: String
        let listenOnLAN: Bool
        let decryptHTTPS: Bool
        let sslHosts: String
        let rewriteEnabled: Bool
        let headerRules: [CustomsHeaderRule]
    }

    private func temporaryStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomsPresentationTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func testDefaultSwimlaneIsEnabledAndEmpty() async throws {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await MainActor.run {
            let model = CustomsViewModel(storageURL: url)
            let rule = try XCTUnwrap(model.headerRules.first)
            XCTAssertEqual(model.headerRules.count, 1)
            XCTAssertEqual(rule.name, "swimlane")
            XCTAssertEqual(rule.value, "")
            XCTAssertTrue(rule.isEnabled)
            XCTAssertNil(model.validateRules())
            XCTAssertTrue(model.listenOnLAN)
            XCTAssertTrue(model.decryptHTTPS)
            XCTAssertEqual(model.sslHostsText, "*")
            XCTAssertFalse(model.isRunning)
            XCTAssertFalse(model.isStarting)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testRuleDuplicateNamesAreCaseInsensitive() async {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await MainActor.run {
            let model = CustomsViewModel(storageURL: url)
            model.headerRules = [CustomsHeaderRule(name: "X-Test", value: "one"),
                                 CustomsHeaderRule(name: "x-TEST", value: "two")]
            XCTAssertNotNil(model.validateRules())
            model.headerRules[1].isEnabled = false
            XCTAssertNil(model.validateRules())
        }
    }

    func testRuleCRLFInNameOrValueIsInvalid() async {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await MainActor.run {
            let model = CustomsViewModel(storageURL: url)
            for rule in [CustomsHeaderRule(name: "X-Test\r\nInjected", value: "value"),
                         CustomsHeaderRule(name: "X-Test", value: "value\r\nInjected: yes")] {
                model.headerRules = [rule]
                XCTAssertNotNil(model.validateRules())
                model.saveRules()
                XCTAssertNotNil(model.message)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    func testSavedConfigurationJSONExcludesTransactions() async throws {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await MainActor.run {
            let model = CustomsViewModel(storageURL: url)
            model.portText = "9999"
            model.decryptHTTPS = true
            model.sslHostsText = "*.example.test"
            model.rewriteEnabled = false
            model.headerRules = [CustomsHeaderRule(name: "X-Test", value: "saved")]
            var transaction = CustomsTransaction(method: "POST", url: "https://example.test/private-transaction")
            transaction.requestBody = Data("private-request-body".utf8)
            transaction.responseBody = Data("private-response-body".utf8)
            model.transactions = [transaction]
            model.selectedID = transaction.id
            model.saveRules()
            XCTAssertNil(model.message)
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(StoredSettings.self, from: data)
            XCTAssertEqual(settings.port, "9999")
            XCTAssertTrue(settings.listenOnLAN)
            XCTAssertTrue(settings.decryptHTTPS)
            XCTAssertEqual(settings.sslHosts, "*.example.test")
            XCTAssertFalse(settings.rewriteEnabled)
            XCTAssertEqual(settings.headerRules.map(\.name), ["swimlane", "X-Test"])
            XCTAssertEqual(settings.headerRules.map(\.value), ["", "saved"])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(json.keys), Set(["port", "listenOnLAN", "decryptHTTPS", "sslHosts", "rewriteEnabled", "headerRules"]))
            XCTAssertNil(json["transactions"])
            XCTAssertNil(json["selectedID"])
            let restored = CustomsViewModel(storageURL: url)
            XCTAssertTrue(restored.transactions.isEmpty)
            XCTAssertNil(restored.selectedID)
        }
    }

    func testLoadingPersistedLANAndHTTPSPreservesEnabledDefaults() async throws {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await MainActor.run {
            let model = CustomsViewModel(storageURL: url)
            model.listenOnLAN = true
            model.portText = "9999"
            model.headerRules[0].value = "test-lane"
            model.saveRules()
            XCTAssertNil(model.message)
            let saved = try JSONDecoder().decode(StoredSettings.self, from: Data(contentsOf: url))
            XCTAssertTrue(saved.listenOnLAN)
            XCTAssertTrue(saved.decryptHTTPS)
            let restored = CustomsViewModel(storageURL: url)
            XCTAssertTrue(restored.listenOnLAN)
            XCTAssertTrue(restored.decryptHTTPS)
            XCTAssertEqual(restored.portText, "9999")
            XCTAssertEqual(restored.headerRules.first?.value, "test-lane")
        }
    }

    func testLoadingExplicitLANAndHTTPSChoicesDoesNotOverwriteUserSettings() async {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await MainActor.run {
            for lan in [false, true] {
                for decrypt in [false, true] {
                    let model = CustomsViewModel(storageURL: url)
                    model.listenOnLAN = lan
                    model.decryptHTTPS = decrypt
                    model.saveRules()
                    XCTAssertNil(model.message)
                    let restored = CustomsViewModel(storageURL: url)
                    XCTAssertEqual(restored.listenOnLAN, lan)
                    XCTAssertEqual(restored.decryptHTTPS, decrypt)
                    XCTAssertFalse(restored.isRunning)
                    XCTAssertFalse(restored.isStarting)
                }
            }
        }
    }
}

nonisolated final class CustomsRequestTreeTests: XCTestCase {
    private func temporaryStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomsRequestTreeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @MainActor
    private func makeVM() -> CustomsViewModel {
        let url = temporaryStorageURL()
        let model = CustomsViewModel(storageURL: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        return model
    }

    private func request(_ url: String, method: String = "GET", status: Int? = nil,
                         error: String? = nil) -> CustomsTransaction {
        var transaction = CustomsTransaction(method: method, url: url)
        transaction.statusCode = status
        transaction.error = error
        return transaction
    }

    @MainActor
    func testEmptyWhitespaceAndCaseInsensitiveHostSearchIncludesAllHostPaths() async {
        let model = makeVM()
        let first = request("https://alpha.test/api")
        let second = request("https://alpha.test/other")
        let other = request("https://beta.test/api")
        model.transactions = [first, second, other]
        for query in ["", " \n\t "] {
            model.treeSearchText = query
            XCTAssertFalse(model.isTreeSearching)
            XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [first.id, second.id, other.id])
            XCTAssertEqual(model.requestTreeNodes.map(\.host), ["alpha.test", "beta.test"])
            XCTAssertEqual(model.requestTreeNodes.map(\.count), [2, 1])
        }
        model.treeSearchText = " \nALPHA.TeSt\t "
        XCTAssertTrue(model.isTreeSearching)
        XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.path), ["/api", "/other"])
        XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.count), [1, 1])
    }

    @MainActor
    func testPathSearchRetainsAncestorsCountsDuplicatesAndStableStructuralIDs() async {
        let model = makeVM()
        let records = [request("https://zeta.test/api/z"), request("https://alpha.test/api/b"),
                       request("https://alpha.test/api/a"), request("https://alpha.test/api/a"),
                       request("https://alpha.test/other")]
        model.transactions = records
        model.treeSearchText = " /API/ "
        let nodes = model.requestTreeNodes
        XCTAssertEqual(nodes.map(\.host), ["alpha.test", "zeta.test"])
        XCTAssertEqual(nodes.map(\.count), [3, 1])
        XCTAssertEqual(nodes.map(\.id), [.init(host: "alpha.test", path: nil), .init(host: "zeta.test", path: nil)])
        XCTAssertEqual(nodes[0].children?.map(\.path), ["/api/a", "/api/b"])
        XCTAssertEqual(nodes[0].children?.map(\.count), [2, 1])
        XCTAssertEqual(nodes[0].children?.map(\.id), [.init(host: "alpha.test", path: "/api/a"),
                                                   .init(host: "alpha.test", path: "/api/b")])
        XCTAssertEqual(nodes[1].children?.map(\.id), [.init(host: "zeta.test", path: "/api/z")])
        let originalIDs = nodes.flatMap { [$0.id] + ($0.children ?? []).map(\.id) }
        XCTAssertEqual(Set(originalIDs).count, 5)
        model.transactions = Array(records.reversed())
        XCTAssertEqual(model.requestTreeNodes.flatMap { [$0.id] + ($0.children ?? []).map(\.id) }, originalIDs)
        XCTAssertEqual(model.requestTreeNodes.map(\.count), [3, 1])
        // These pairs would collide if identity were host + "/" + path.
        XCTAssertNotEqual(CustomsRequestTreeNode.ID(host: "a/b", path: "c"),
                          CustomsRequestTreeNode.ID(host: "a", path: "b/c"))
    }

    @MainActor
    func testFullURLSchemeAndPortSearchUsesFilteredPoolDespiteIdenticalGroups() async {
        let model = makeVM()
        let secure = request("https://same.test:8443/api")
        let plain = request("http://same.test:8080/api")
        let standard = request("https://same.test/api")
        model.transactions = [secure, plain, standard]
        XCTAssertEqual(model.requestTreeNodes.map(\.count), [3])
        for (query, expected) in [(" HTTPS://SAME.TEST:8443 ", secure), (":8080", plain)] {
            model.treeSearchText = query
            XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [expected.id])
            XCTAssertEqual(model.requestTreeNodes.first?.id, .init(host: "same.test", path: nil))
            XCTAssertEqual(model.requestTreeNodes.first?.count, 1)
            XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.id), [.init(host: "same.test", path: "/api")])
            XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.count), [1])
        }
        model.treeSearchText = "https://"
        XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [secure.id, standard.id])
        XCTAssertEqual(model.requestTreeNodes.first?.count, 2)
    }

    @MainActor
    func testPercentEncodedChineseSearchMatchesDecodedURLWithoutChangingPathIdentity() async {
        let model = makeVM()
        let chinese = request("https://example.test/%E4%B8%AD%E6%96%87?q=%E6%B5%8B%E8%AF%95")
        let other = request("https://example.test/plain")
        model.transactions = [chinese, other]
        for query in [" 中文 ", "测试", "%E4%B8%AD"] {
            model.treeSearchText = query
            XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [chinese.id])
            XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.id),
                           [.init(host: "example.test", path: chinese.groupingPath)])
        }
        model.treeSearchText = ""
        model.searchText = "中文"
        XCTAssertTrue(model.treeFilteredTransactions.isEmpty, "Global search must retain its raw-URL matching rule")
        XCTAssertNil(model.selectedTransaction)
    }

    @MainActor
    func testTreeSearchANDsWithExistingGlobalURLMethodStatusAndErrorRules() async {
        let model = makeVM()
        let get = request("https://alpha.test/api?tag=needle", status: 200)
        let post = request("https://alpha.test/api", method: "POST", status: 503, error: "UPSTREAM timeout")
        let pending = request("https://alpha.test/api/pending", method: "PATCH")
        let outside = request("https://beta.test/api?tag=needle", method: "POST", status: 503, error: "upstream timeout")
        model.transactions = [get, post, pending, outside]
        model.treeSearchText = "alpha.test"
        for (query, expected) in [(" NeEdLe ", get), (" pOsT ", post), ("503", post),
                                  (" TiMeOuT ", post), ("0", get)] {
            model.searchText = query
            let expectedIDs = query == "0" ? [get.id, post.id, pending.id] : [expected.id]
            XCTAssertEqual(model.treeFilteredTransactions.map(\.id), expectedIDs, "Global query: \(query)")
            XCTAssertEqual(model.requestTreeNodes.map(\.count), [expectedIDs.count])
            XCTAssertEqual(model.filteredTransactions.map(\.id), expectedIDs)
        }
        model.searchText = "get"
        model.treeSearchText = "POST"
        XCTAssertTrue(model.treeFilteredTransactions.isEmpty, "Tree search must not match the HTTP method")
    }

    @MainActor
    func testSelectingPathIsExactNotSubstringAndDoesNotNarrowTreeCounts() async {
        let model = makeVM()
        let api = request("https://alpha.test/api")
        let repeated = request("https://alpha.test/api")
        let apiV2 = request("https://alpha.test/apiv2")
        let query = request("https://alpha.test/api?q=1")
        let otherHost = request("https://beta.test/api")
        model.transactions = [apiV2, api, repeated, query, otherHost]
        model.selectTreeNode(host: "alpha.test", path: "/api")
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.filteredTransactions.map(\.id), [api.id, repeated.id, query.id])
        XCTAssertEqual(model.selectedID, api.id)
        XCTAssertEqual(model.selectedTransaction?.id, api.id)
        XCTAssertEqual(model.requestTreeNodes.map(\.count), [4, 1])
        XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.count), [3, 1])
        XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.id),
                       [.init(host: "alpha.test", path: "/api"), .init(host: "alpha.test", path: "/apiv2")])
        model.selectTreeTransaction(id: query.id)
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedID, query.id)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [api.id, repeated.id, query.id])
        XCTAssertEqual(model.selectedTransaction?.id, query.id)
    }

    @MainActor
    func testQueryVariantsShareOneBranchPreservingCaptureOrderMethodsAndStreamingIDs() async throws {
        let model = makeVM()
        let rawPaths = ["/api", "/api?", "/api?a=1", "/api?b=2&a=%2F"]
        let methods = ["GET", "OPTIONS", "GET", "OPTIONS"]
        let records = rawPaths.enumerated().map { index, path in
            var transaction = request("https://alpha.test" + path, method: methods[index])
            transaction.startedAt = Date(timeIntervalSince1970: Double(4 - index))
            return transaction
        }
        model.transactions = records
        let host = try XCTUnwrap(model.requestTreeNodes.first)
        let paths = try XCTUnwrap(host.children)
        XCTAssertEqual(paths.count, 1)
        let branch = try XCTUnwrap(paths.first)
        let leaves = try XCTUnwrap(branch.children)
        XCTAssertEqual(host.count, 4)
        XCTAssertEqual(branch.count, 4)
        XCTAssertEqual(branch.id, .init(host: "alpha.test", path: "/api"))
        XCTAssertEqual(leaves.map(\.id), records.map {
            .init(host: "alpha.test", path: "/api", transactionID: $0.id)
        })
        XCTAssertEqual(Set(leaves.map(\.id)).count, 4)
        XCTAssertEqual(leaves.map { $0.transaction?.method }, methods.map { Optional($0) })
        XCTAssertEqual(leaves.map { $0.transaction?.url }, records.map { Optional($0.url) })
        XCTAssertEqual(leaves.map { $0.transaction?.path }, rawPaths.map { Optional($0) })
        XCTAssertEqual(records.map(\.groupingPath), Array(repeating: "/api", count: 4))
        XCTAssertTrue(leaves.allSatisfy { $0.path == "/api" && $0.count == 1 && $0.children == nil })
        model.selectTreeTransaction(id: records[3].id)
        model.transactions[3].statusCode = 202
        model.transactions[3].responseBody = Data("streamed query response".utf8)
        let updatedHost = try XCTUnwrap(model.requestTreeNodes.first)
        let updatedBranch = try XCTUnwrap(updatedHost.children?.first)
        XCTAssertEqual(updatedHost.id, host.id)
        XCTAssertEqual(updatedBranch.id, branch.id)
        XCTAssertEqual(updatedBranch.children?.map(\.id), leaves.map(\.id))
        XCTAssertEqual(updatedBranch.count, 4)
        XCTAssertEqual(model.selectedID, records[3].id)
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedTransaction?.statusCode, 202)
        XCTAssertEqual(model.selectedTransaction?.responseBody, Data("streamed query response".utf8))
        XCTAssertEqual(model.transactions.map(\.url), records.map(\.url))
        XCTAssertEqual(model.transactions.map(\.path), rawPaths)
    }

    @MainActor
    func testQueryLeafAndPathSelectionIncludeOnlyExactSameHostPathVariants() async {
        let model = makeVM()
        let records = [request("https://alpha.test/api"), request("https://alpha.test/api?"),
                       request("https://alpha.test/api?a=1", method: "OPTIONS"),
                       request("https://alpha.test/api?b=2")]
        let nested = request("https://alpha.test/api/child?a=1")
        let substring = request("https://alpha.test/apiv2?a=1")
        let otherHost = request("https://beta.test/api?a=1")
        model.transactions = [nested, otherHost] + records + [substring]
        model.selectTreeTransaction(id: records[2].id)
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedID, records[2].id)
        XCTAssertEqual(model.selectedTransaction?.url, records[2].url)
        XCTAssertEqual(model.filteredTransactions.map(\.id), records.map(\.id))
        model.selectTreeNode(host: "alpha.test", path: "/api/child")
        XCTAssertEqual(model.filteredTransactions.map(\.id), [nested.id])
        model.selectTreeNode(host: "alpha.test", path: records[2].groupingPath)
        XCTAssertEqual(model.filteredTransactions.map(\.id), records.map(\.id))
        XCTAssertEqual(model.selectedID, records[0].id)
        XCTAssertEqual(model.requestTreeNodes.map(\.count), [6, 1])
        XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.path), ["/api", "/api/child", "/apiv2"])
        XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.count), [4, 1, 1])
    }

    @MainActor
    func testQuerySearchFiltersLeavesButPreservesBranchAndSelectionWhenCleared() async throws {
        for useTreeSearch in [true, false] {
            let model = makeVM()
            let records = [request("https://alpha.test/api"), request("https://alpha.test/api?"),
                           request("https://alpha.test/api?tag=needle"),
                           request("https://alpha.test/api?other=needle"),
                           request("https://alpha.test/api?tag=haystack")]
            model.transactions = records
            model.selectTreeTransaction(id: records[4].id)
            let branchID = try XCTUnwrap(model.requestTreeNodes.first?.children?.first?.id)
            if useTreeSearch { model.treeSearchText = "needle" } else { model.searchText = "needle" }
            XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [records[2].id, records[3].id])
            XCTAssertEqual(model.filteredTransactions.map(\.id), [records[2].id, records[3].id])
            XCTAssertEqual(model.selectedPath, "/api")
            XCTAssertEqual(model.selectedID, records[2].id)
            let branch = try XCTUnwrap(model.requestTreeNodes.first?.children?.first)
            XCTAssertEqual(branch.id, branchID)
            XCTAssertEqual(branch.count, 2)
            XCTAssertEqual(model.requestTreeNodes.first?.count, 2)
            XCTAssertEqual(branch.children?.map(\.id.transactionID), [records[2].id, records[3].id])
            XCTAssertTrue(branch.children?.allSatisfy { $0.path == "/api" && $0.count == 1 } == true)
            if useTreeSearch { model.treeSearchText = "" } else { model.searchText = "" }
            XCTAssertEqual(model.selectedHost, "alpha.test")
            XCTAssertEqual(model.selectedPath, "/api")
            XCTAssertEqual(model.selectedID, records[2].id)
            XCTAssertEqual(model.filteredTransactions.map(\.id), records.map(\.id))
            XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.id), [branchID])
            XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.count), [5])
            XCTAssertEqual(model.requestTreeNodes.first?.children?.first?.children?.count, 5)
        }
    }

    @MainActor
    func testPruningDifferentQuerySiblingsPreservesBranchAndFallsBackWithinPath() async throws {
        let model = makeVM()
        let unrelated = request("https://alpha.test/other")
        let first = request("https://alpha.test/api?a=1")
        let second = request("https://alpha.test/api?b=2")
        let selected = request("https://alpha.test/api?c=3")
        model.transactions = [unrelated, first, second, selected]
        model.selectTreeTransaction(id: selected.id)
        let branchID = try XCTUnwrap(model.requestTreeNodes.first?.children?.first?.id)
        model.transactions.removeAll { $0.id == second.id }
        XCTAssertEqual(model.selectedID, selected.id)
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.requestTreeNodes.first?.children?.first?.id, branchID)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [first.id, selected.id])
        model.transactions.removeAll { $0.id == selected.id }
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedID, first.id, "Fall back to a different-query sibling, not the earlier other path")
        XCTAssertEqual(model.selectedTransaction?.path, "/api?a=1")
        XCTAssertEqual(model.requestTreeNodes.first?.children?.first?.id, branchID)
        XCTAssertEqual(model.requestTreeNodes.first?.children?.first?.count, 1)
        model.selectTreeTransaction(id: selected.id)
        XCTAssertEqual(model.selectedID, first.id, "A pruned query leaf must remain a no-op")
        model.transactions.removeAll { $0.id == first.id }
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.selectedID, unrelated.id)
    }

    @MainActor
    func testEncodedSlashAndPercentEscapeCaseRemainDistinctRawPathBranchIDs() async throws {
        let model = makeVM()
        let rawPaths = ["/a%2Fb", "/a%2Fb?q=%2f", "/a/b?q=1", "/a%2fb?q=2", "/a%2fb?"]
        let records = rawPaths.map { request("https://alpha.test" + $0) }
        model.transactions = records
        let paths = try XCTUnwrap(model.requestTreeNodes.first?.children)
        let expectedPaths = ["/a%2Fb", "/a%2fb", "/a/b"]
        XCTAssertEqual(paths.map(\.path), expectedPaths.map { Optional($0) })
        XCTAssertEqual(paths.map(\.id), expectedPaths.map { .init(host: "alpha.test", path: $0) })
        XCTAssertEqual(Set(paths.map(\.id)).count, 3)
        XCTAssertEqual(paths.map(\.count), [2, 2, 1])
        XCTAssertEqual(records.map(\.groupingPath), ["/a%2Fb", "/a%2Fb", "/a/b", "/a%2fb", "/a%2fb"])
        XCTAssertEqual(records.map(\.path), rawPaths)
        for (path, indices) in [("/a%2Fb", [0, 1]), ("/a%2fb", [3, 4]), ("/a/b", [2])] {
            let selectedIndex = try XCTUnwrap(indices.last)
            model.selectTreeTransaction(id: records[selectedIndex].id)
            XCTAssertEqual(model.selectedPath, path)
            XCTAssertEqual(model.filteredTransactions.map(\.id), indices.map { records[$0].id })
            let branch = try XCTUnwrap(paths.first { $0.path == path })
            XCTAssertEqual(branch.children?.map(\.id), indices.map {
                .init(host: "alpha.test", path: path, transactionID: records[$0].id)
            })
        }
        XCTAssertEqual(model.transactions.map(\.url), records.map(\.url))
        XCTAssertEqual(model.transactions.map(\.path), rawPaths)
    }

    @MainActor
    func testRootQueryVariantsGroupTogetherButOPTIONSAsteriskRemainsDistinct() async throws {
        let model = makeVM()
        let urls = ["https://alpha.test", "https://alpha.test?", "https://alpha.test?a=1",
                    "https://alpha.test/", "https://alpha.test/?", "https://alpha.test/?b=2&a=%2F"]
        let roots = urls.enumerated().map { index, url in
            request(url, method: index.isMultiple(of: 2) ? "GET" : "OPTIONS")
        }
        var asterisk = request("https://alpha.test/", method: "OPTIONS")
        asterisk.requestTarget = "*"
        model.transactions = roots + [asterisk]
        let paths = try XCTUnwrap(model.requestTreeNodes.first?.children)
        XCTAssertEqual(paths.map(\.id), [.init(host: "alpha.test", path: "*"), .init(host: "alpha.test", path: "/")])
        XCTAssertEqual(paths.map(\.count), [1, 6])
        XCTAssertEqual(model.requestTreeNodes.first?.count, 7)
        let asteriskBranch = try XCTUnwrap(paths.first { $0.path == "*" })
        let rootBranch = try XCTUnwrap(paths.first { $0.path == "/" })
        XCTAssertEqual(asteriskBranch.children?.map(\.id), [.init(host: "alpha.test", path: "*", transactionID: asterisk.id)])
        XCTAssertEqual(rootBranch.children?.map(\.id.transactionID), roots.map { Optional($0.id) })
        XCTAssertEqual(roots.map(\.groupingPath), Array(repeating: "/", count: 6))
        XCTAssertEqual(roots.map(\.path), ["/", "/?", "/?a=1", "/", "/?", "/?b=2&a=%2F"])
        XCTAssertEqual(asterisk.groupingPath, "*")
        XCTAssertEqual(asterisk.path, "*")
        model.selectTreeTransaction(id: roots[5].id)
        XCTAssertEqual(model.selectedPath, "/")
        XCTAssertEqual(model.filteredTransactions.map(\.id), roots.map(\.id))
        XCTAssertEqual(model.selectedID, roots[5].id)
        model.selectTreeTransaction(id: asterisk.id)
        XCTAssertEqual(model.selectedPath, "*")
        XCTAssertEqual(model.filteredTransactions.map(\.id), [asterisk.id])
        XCTAssertEqual(model.selectedTransaction?.requestTarget, "*")
        model.selectTreeNode(host: "alpha.test", path: "/")
        XCTAssertEqual(model.filteredTransactions.map(\.id), roots.map(\.id))
        XCTAssertEqual(model.transactions.map(\.url), urls + [asterisk.url])
        XCTAssertEqual(model.transactions.last?.path, "*")
    }

    @MainActor
    func testQueryAndFragmentDoNotParticipateInEncodedPathGrouping() async throws {
        let model = makeVM()
        let urls = ["https://alpha.test/api#first", "https://alpha.test/api?a=1#second",
                    "https://alpha.test/api?#third", "https://alpha.test/api#%2Fother"]
        let records = urls.map { request($0) }
        model.transactions = records
        let paths = try XCTUnwrap(model.requestTreeNodes.first?.children)
        XCTAssertEqual(paths.map(\.id), [.init(host: "alpha.test", path: "/api")])
        XCTAssertEqual(paths.map(\.count), [4])
        XCTAssertEqual(paths.first?.children?.map(\.id.transactionID), records.map { Optional($0.id) })
        XCTAssertEqual(records.map(\.groupingPath), Array(repeating: "/api", count: 4))
        XCTAssertEqual(records.map(\.path), ["/api", "/api?a=1", "/api?", "/api"])
        model.selectTreeTransaction(id: records[1].id)
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedID, records[1].id)
        XCTAssertEqual(model.filteredTransactions.map(\.id), records.map(\.id))
        XCTAssertEqual(model.transactions.map(\.url), urls)
    }

    @MainActor
    func testSelectingPathHostAndAllKeepsBothQueriesAndDirectHostSetterClearsPath() async {
        let model = makeVM()
        let a = request("https://alpha.test/api"), b = request("https://beta.test/api")
        model.transactions = [a, b]
        model.searchText = " GET "
        model.treeSearchText = " /API "
        model.selectTreeNode(host: "alpha.test", path: "/api")
        model.selectedHost = "alpha.test"
        XCTAssertEqual(model.selectedPath, "/api", "Assigning the same host must preserve the path")
        model.selectedHost = "beta.test"
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [b.id])
        model.selectTreeNode(host: "alpha.test", path: "/api")
        XCTAssertEqual(model.selectedPath, "/api")
        model.selectTreeNode(host: "alpha.test")
        XCTAssertNil(model.selectedPath)
        model.selectTreeNode(host: nil)
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [a.id, b.id])
        XCTAssertEqual(model.searchText, " GET ")
        XCTAssertEqual(model.treeSearchText, " /API ")
    }

    @MainActor
    func testInvisibleHostClearsBranchAndReselectsFirstVisibleDetailForEitherSearch() async {
        for useTreeSearch in [true, false] {
            let model = makeVM()
            let old = request("https://old.test/api", method: "POST")
            let first = request("https://new.test/api"), second = request("https://new.test/other")
            model.transactions = [old, first, second]
            model.selectTreeNode(host: "old.test", path: "/api")
            XCTAssertEqual(model.selectedTransaction?.id, old.id)
            if useTreeSearch { model.treeSearchText = "new.test" } else { model.searchText = "GET" }
            XCTAssertNil(model.selectedHost)
            XCTAssertNil(model.selectedPath)
            XCTAssertEqual(model.filteredTransactions.map(\.id), [first.id, second.id])
            XCTAssertEqual(model.selectedID, first.id)
            XCTAssertEqual(model.selectedTransaction?.id, first.id)
            model.selectedID = old.id
            XCTAssertNil(model.selectedTransaction, "Detail must not expose a manually assigned invisible row")
            let unchangedRecords = model.transactions
            model.transactions = unchangedRecords
            XCTAssertEqual(model.selectedID, first.id)
        }
    }

    @MainActor
    func testInvisiblePathFallsBackToStillMatchingHostForEitherSearch() async {
        for useTreeSearch in [true, false] {
            let model = makeVM()
            let old = request("https://alpha.test/old", method: "POST")
            let sibling = request("https://alpha.test/keep")
            let otherHost = request("https://beta.test/keep")
            model.transactions = [old, otherHost, sibling]
            model.selectTreeNode(host: "alpha.test", path: "/old")
            if useTreeSearch { model.treeSearchText = "/keep" } else { model.searchText = "GET" }
            XCTAssertEqual(model.selectedHost, "alpha.test")
            XCTAssertNil(model.selectedPath)
            XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [otherHost.id, sibling.id])
            XCTAssertEqual(model.filteredTransactions.map(\.id), [sibling.id])
            XCTAssertEqual(model.selectedID, sibling.id)
            XCTAssertEqual(model.selectedTransaction?.id, sibling.id)
        }
    }

    @MainActor
    func testNoResultsClearsBranchRowAndDetail() async {
        let model = makeVM()
        model.transactions = [request("https://alpha.test/api")]
        model.selectTreeNode(host: "alpha.test", path: "/api")
        model.treeSearchText = "absent"
        XCTAssertTrue(model.treeFilteredTransactions.isEmpty)
        XCTAssertTrue(model.requestTreeNodes.isEmpty)
        XCTAssertTrue(model.filteredTransactions.isEmpty)
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
        model.treeSearchText = ""
        XCTAssertNotNil(model.selectedID)
        model.searchText = "absent"
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
    }

    @MainActor
    func testNewRecordsAndInPlaceStreamingStatusUpdatesReconcileMatchingRow() async {
        let model = makeVM()
        let pending = request("https://alpha.test/api")
        model.treeSearchText = "alpha.test"
        model.searchText = "201"
        model.transactions = [pending]
        XCTAssertNil(model.selectedID)
        let incoming = request("https://alpha.test/new", status: 201)
        model.transactions.append(incoming)
        XCTAssertEqual(model.selectedID, incoming.id)
        XCTAssertEqual(model.requestTreeNodes.first?.count, 1)
        model.transactions[0].statusCode = 201
        XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [pending.id, incoming.id])
        XCTAssertEqual(model.selectedID, incoming.id, "An already visible selection should not jump")
        model.transactions[1].statusCode = 500
        XCTAssertEqual(model.selectedID, pending.id)
        XCTAssertEqual(model.selectedTransaction?.statusCode, 201)
        model.transactions[0].statusCode = 500
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
        model.transactions[1].statusCode = 201
        XCTAssertEqual(model.selectedID, incoming.id)
        XCTAssertEqual(model.selectedTransaction?.id, incoming.id)
    }

    @MainActor
    func testPruningTransactionsReselectsVisibleOnlyThenFallsBackFromPathAndHost() async {
        let model = makeVM()
        let hidden = request("https://hidden.test/api", method: "POST")
        let first = request("https://alpha.test/api"), second = request("https://alpha.test/api")
        let sibling = request("https://alpha.test/other"), other = request("https://beta.test/api")
        model.transactions = [hidden, first, second, sibling, other]
        model.searchText = "GET"
        model.selectTreeNode(host: "alpha.test", path: "/api")
        model.transactions.removeAll { $0.id == first.id }
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(model.selectedPath, "/api")
        model.transactions.removeAll { $0.id == second.id }
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.selectedTransaction?.id, sibling.id)
        model.transactions.removeAll { $0.id == sibling.id }
        XCTAssertNil(model.selectedHost)
        XCTAssertEqual(model.selectedTransaction?.id, other.id)
        model.transactions.removeAll { $0.id == other.id }
        XCTAssertEqual(model.transactions.map(\.id), [hidden.id])
        XCTAssertTrue(model.requestTreeNodes.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
    }

    @MainActor
    func testClearKeepsSearchesButEmptiesGroupsBranchAndDetail() async {
        let model = makeVM()
        model.transactions = [request("https://alpha.test/api")]
        model.searchText = " GET "
        model.treeSearchText = " /API "
        model.selectTreeNode(host: "alpha.test", path: "/api")
        model.clear()
        XCTAssertTrue(model.transactions.isEmpty)
        XCTAssertTrue(model.requestTreeNodes.isEmpty)
        XCTAssertTrue(model.treeFilteredTransactions.isEmpty)
        XCTAssertTrue(model.filteredTransactions.isEmpty)
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
        XCTAssertEqual(model.searchText, " GET ")
        XCTAssertEqual(model.treeSearchText, " /API ")
    }

    @MainActor
    func testResetRequestFiltersClearsAllFourAndReconcilesVisibleSelection() async {
        let model = makeVM()
        let first = request("https://beta.test/other", method: "POST")
        let selected = request("https://alpha.test/api")
        model.transactions = [first, selected]
        model.searchText = "GET"
        model.treeSearchText = "alpha.test"
        model.selectTreeNode(host: "alpha.test", path: "/api")
        model.resetRequestFilters()
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.treeSearchText, "")
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [first.id, selected.id])
        XCTAssertEqual(model.selectedID, selected.id, "Reset preserves a still-visible row")
        XCTAssertEqual(model.selectedTransaction?.id, selected.id)
        model.selectedID = UUID()
        model.resetRequestFilters()
        XCTAssertEqual(model.selectedID, first.id)
        model.transactions = []
        model.resetRequestFilters()
        XCTAssertNil(model.selectedID)
    }

    @MainActor
    func testUnmatchedTreeNodeSelectionIsNoOpIncludingSearchHiddenNodes() async {
        let model = makeVM()
        let selected = request("https://alpha.test/api"), hidden = request("https://beta.test/api")
        model.transactions = [selected, hidden]
        model.searchText = "GET"
        model.treeSearchText = "alpha.test"
        model.selectTreeNode(host: "alpha.test", path: "/api")
        for (host, path) in [("missing.test", Optional<String>.none), ("alpha.test", "/missing"),
                             ("beta.test", "/api")] {
            model.selectTreeNode(host: host, path: path)
            XCTAssertEqual(model.selectedHost, "alpha.test")
            XCTAssertEqual(model.selectedPath, "/api")
            XCTAssertEqual(model.selectedID, selected.id)
            XCTAssertEqual(model.selectedTransaction?.id, selected.id)
            XCTAssertEqual(model.searchText, "GET")
            XCTAssertEqual(model.treeSearchText, "alpha.test")
        }
    }

    @MainActor
    func testExplicitSaveExcludesTreeSearchPathAndOtherTransientFilters() async throws {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = CustomsViewModel(storageURL: url)
        model.transactions = [request("https://alpha.test/private-api")]
        model.searchText = "GET"
        model.treeSearchText = "private-api"
        model.selectTreeNode(host: "alpha.test", path: "/private-api")
        model.portText = "9999"
        model.headerRules[0].value = "saved-lane"
        XCTAssertEqual(model.selectedPath, "/private-api")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        model.saveRules()
        XCTAssertNil(model.message)
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["port", "listenOnLAN", "decryptHTTPS", "sslHosts", "rewriteEnabled", "headerRules"]))
        for key in ["treeSearchText", "searchText", "selectedHost", "selectedPath", "selectedID", "transactions"] {
            XCTAssertNil(json[key], "Transient field must not be persisted: \(key)")
        }
        let restored = CustomsViewModel(storageURL: url)
        XCTAssertEqual(restored.portText, "9999")
        XCTAssertEqual(restored.headerRules.first?.value, "saved-lane")
        XCTAssertEqual(restored.treeSearchText, "")
        XCTAssertEqual(restored.searchText, "")
        XCTAssertNil(restored.selectedHost)
        XCTAssertNil(restored.selectedPath)
        XCTAssertNil(restored.selectedID)
        XCTAssertTrue(restored.transactions.isEmpty)
        XCTAssertTrue(restored.requestTreeNodes.isEmpty)
        XCTAssertEqual(model.treeSearchText, "private-api")
        XCTAssertEqual(model.selectedPath, "/private-api")
    }

    @MainActor
    func testThirteenSameURLLeavesHaveDistinctIDsAndFollowCaptureOrderNotTime() async throws {
        let model = makeVM()
        let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
        let records = (0..<13).map { index in
            var transaction = request("https://alpha.test/api", method: methods[index % methods.count])
            // Concurrent captures may share timestamps; array order is authoritative.
            transaction.startedAt = Date(timeIntervalSince1970: index.isMultiple(of: 2) ? 20 : 10)
            return transaction
        }
        model.transactions = records
        let host = try XCTUnwrap(model.requestTreeNodes.first)
        let paths = try XCTUnwrap(host.children)
        XCTAssertEqual(paths.count, 1)
        let path = try XCTUnwrap(paths.first)
        let leaves = try XCTUnwrap(path.children)
        XCTAssertNil(host.transaction)
        XCTAssertNil(path.transaction)
        XCTAssertEqual(host.count, 13)
        XCTAssertEqual(path.count, leaves.count)
        XCTAssertEqual(leaves.count, 13)
        XCTAssertEqual(leaves.map(\.id.transactionID), records.map { Optional($0.id) })
        XCTAssertEqual(leaves.map { $0.transaction?.method }, records.map { Optional($0.method) })
        XCTAssertEqual(Set(leaves.map(\.id)).count, 13)
        XCTAssertTrue(leaves.allSatisfy { $0.count == 1 && $0.children == nil && $0.transaction != nil })
        XCTAssertEqual(leaves.map(\.host), Array(repeating: "alpha.test", count: 13))
        XCTAssertEqual(leaves.map(\.path), Array(repeating: Optional("/api"), count: 13))
        XCTAssertEqual(host.count, leaves.reduce(0) { $0 + $1.count })
        model.transactions = Array(records.reversed())
        let reversed = try XCTUnwrap(model.requestTreeNodes.first?.children?.first?.children)
        XCTAssertEqual(reversed.map(\.id), Array(leaves.map(\.id).reversed()))
        XCTAssertEqual(model.requestTreeNodes.first?.count, 13)
    }

    @MainActor
    func testCONNECTAndURLWithoutPathRemainIndividualRootPathLeaves() async throws {
        let model = makeVM()
        var tunnel = request("https://alpha.test:443", method: "CONNECT", status: 200)
        tunnel.isTunnel = true
        let get = request("https://alpha.test", status: 204)
        let head = request("http://alpha.test:8080", method: "HEAD")
        model.transactions = [tunnel, get, head]
        let host = try XCTUnwrap(model.requestTreeNodes.first)
        let paths = try XCTUnwrap(host.children)
        XCTAssertEqual(paths.map(\.path), ["/"])
        let path = try XCTUnwrap(paths.first)
        let leaves = try XCTUnwrap(path.children)
        XCTAssertEqual(host.count, 3)
        XCTAssertEqual(path.count, 3)
        XCTAssertEqual(leaves.map { $0.transaction?.id }, [tunnel.id, get.id, head.id])
        XCTAssertEqual(leaves.map { $0.transaction?.method }, ["CONNECT", "GET", "HEAD"])
        XCTAssertEqual(leaves.map(\.path), ["/", "/", "/"])
        XCTAssertTrue(leaves.allSatisfy { $0.count == 1 && $0.children == nil })
        XCTAssertEqual(leaves.first?.transaction?.isTunnel, true)
        XCTAssertEqual(leaves.first?.transaction?.url, tunnel.url)
        model.selectTreeTransaction(id: tunnel.id)
        XCTAssertEqual(model.selectedPath, "/")
        XCTAssertEqual(model.selectedTransaction?.id, tunnel.id)
        XCTAssertEqual(model.selectedTransaction?.isTunnel, true)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [tunnel.id, get.id, head.id])
    }

    @MainActor
    func testSingleRequestStillHasHostPathAndLeafWithCompatibleBranchDefaults() async throws {
        let model = makeVM()
        let transaction = request("https://alpha.test/only", status: 201)
        model.transactions = [transaction]
        XCTAssertEqual(model.requestTreeNodes.count, 1)
        let host = try XCTUnwrap(model.requestTreeNodes.first)
        let paths = try XCTUnwrap(host.children)
        XCTAssertEqual(paths.count, 1)
        let path = try XCTUnwrap(paths.first)
        let leaves = try XCTUnwrap(path.children)
        XCTAssertEqual(leaves.count, 1, "Do not collapse a single request into its path branch")
        let leaf = try XCTUnwrap(leaves.first)
        XCTAssertEqual([host.count, path.count, leaf.count], [1, 1, 1])
        XCTAssertNil(host.transaction)
        XCTAssertNil(path.transaction)
        XCTAssertNil(leaf.children)
        XCTAssertEqual(leaf.transaction?.id, transaction.id)
        XCTAssertEqual(leaf.transaction?.statusCode, 201)
        XCTAssertEqual(host.id, .init(host: "alpha.test", path: nil))
        XCTAssertEqual(path.id, .init(host: "alpha.test", path: "/only"))
        XCTAssertNil(host.id.transactionID)
        XCTAssertNil(path.id.transactionID)
        XCTAssertEqual(leaf.id, .init(host: "alpha.test", path: "/only", transactionID: transaction.id))
        let defaultBranch = CustomsRequestTreeNode(host: "alpha.test", path: "/only", count: 1)
        XCTAssertNil(defaultBranch.transaction)
        XCTAssertEqual(defaultBranch.id, path.id)
    }

    @MainActor
    func testStructuralParentAndLeafIDsAreDistinctAndStableAcrossSnapshotUpdates() async throws {
        let model = makeVM()
        var first = request("https://alpha.test/api")
        let second = request("https://alpha.test/api")
        model.transactions = [first, second]
        let host = try XCTUnwrap(model.requestTreeNodes.first)
        let path = try XCTUnwrap(host.children?.first)
        let leaves = try XCTUnwrap(path.children)
        let ids = [host.id, path.id] + leaves.map(\.id)
        XCTAssertEqual(Set(ids).count, 4)
        XCTAssertNotEqual(host.id, path.id)
        XCTAssertNotEqual(path.id, leaves[0].id)
        XCTAssertNotEqual(leaves[0].id, leaves[1].id)
        first.statusCode = 202
        first.responseBody = Data("streamed".utf8)
        first.finishedAt = first.startedAt.addingTimeInterval(2)
        model.transactions[0] = first
        let updatedHost = try XCTUnwrap(model.requestTreeNodes.first)
        let updatedPath = try XCTUnwrap(updatedHost.children?.first)
        let updatedLeaves = try XCTUnwrap(updatedPath.children)
        XCTAssertEqual([updatedHost.id, updatedPath.id] + updatedLeaves.map(\.id), ids)
        XCTAssertEqual(updatedHost.count, 2)
        XCTAssertEqual(updatedPath.count, 2)
        XCTAssertEqual(updatedLeaves.map(\.count), [1, 1])
        XCTAssertEqual(updatedLeaves[0].transaction?.statusCode, 202)
        XCTAssertEqual(updatedLeaves[0].transaction?.responseBody, first.responseBody)
        XCTAssertNil(leaves[0].transaction?.statusCode, "Earlier nodes retain their original value snapshot")
        XCTAssertEqual(leaves[0].transaction?.responseBody, Data())
        XCTAssertNotEqual(CustomsRequestTreeNode.ID(host: "a/b", path: "c", transactionID: first.id),
                          CustomsRequestTreeNode.ID(host: "a", path: "b/c", transactionID: first.id))
    }

    @MainActor
    func testSelectingSecondDuplicatePreservesFullSnapshotAndStreamingResponseWithoutDoubleCounts() async throws {
        let model = makeVM()
        var first = request("https://alpha.test/api", method: "POST", status: 200)
        first.requestBody = Data("first request".utf8)
        first.responseBody = Data("first response".utf8)
        var second = request("https://alpha.test/api", method: "POST", status: 201)
        second.startedAt = first.startedAt
        second.finishedAt = second.startedAt.addingTimeInterval(1)
        second.originalRequestHeaders = [CustomsHeader(name: "X-Lane", value: "original")]
        second.requestHeaders = [CustomsHeader(name: "X-Lane", value: "rewritten")]
        second.rewrittenHeaders = ["X-Lane"]
        second.requestBody = Data("second request".utf8)
        second.requestBodyTruncated = true
        second.requestBodyIncomplete = true
        second.responseHeaders = [CustomsHeader(name: "Content-Type", value: "text/plain")]
        second.responseBody = Data("second response".utf8)
        second.responseBodyTruncated = true
        second.responseByteCount = 4096
        second.responseIsLocal = true
        second.error = "capture incomplete"
        model.transactions = [first, second]
        model.selectTreeTransaction(id: second.id)
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedID, second.id, "Reconciliation must not replace the chosen leaf with the first duplicate")
        XCTAssertEqual(model.filteredTransactions.map(\.id), [first.id, second.id])
        let detail = try XCTUnwrap(model.selectedTransaction)
        let leaves = try XCTUnwrap(model.requestTreeNodes.first?.children?.first?.children)
        let snapshot = try XCTUnwrap(leaves.last?.transaction)
        for value in [detail, snapshot] {
            XCTAssertEqual(value.id, second.id)
            XCTAssertEqual(value.method, second.method)
            XCTAssertEqual(value.url, second.url)
            XCTAssertEqual(value.startedAt, second.startedAt)
            XCTAssertEqual(value.finishedAt, second.finishedAt)
            XCTAssertEqual(value.originalRequestHeaders, second.originalRequestHeaders)
            XCTAssertEqual(value.requestHeaders, second.requestHeaders)
            XCTAssertEqual(value.rewrittenHeaders, second.rewrittenHeaders)
            XCTAssertEqual(value.requestBody, second.requestBody)
            XCTAssertTrue(value.requestBodyTruncated)
            XCTAssertTrue(value.requestBodyIncomplete)
            XCTAssertEqual(value.responseHeaders, second.responseHeaders)
            XCTAssertEqual(value.responseBody, second.responseBody)
            XCTAssertTrue(value.responseBodyTruncated)
            XCTAssertEqual(value.responseByteCount, 4096)
            XCTAssertTrue(value.responseIsLocal)
            XCTAssertEqual(value.statusCode, 201)
            XCTAssertEqual(value.error, second.error)
            XCTAssertFalse(value.isTunnel)
        }
        let leafIDs = leaves.map(\.id)
        second.statusCode = 202
        second.responseBody = Data("second response updated".utf8)
        second.responseByteCount = 8192
        second.finishedAt = second.startedAt.addingTimeInterval(2)
        model.transactions[1] = second
        let updated = try XCTUnwrap(model.requestTreeNodes.first?.children?.first?.children)
        XCTAssertEqual(updated.map(\.id), leafIDs)
        XCTAssertEqual(updated.map(\.count), [1, 1])
        XCTAssertEqual(model.requestTreeNodes.first?.count, 2)
        XCTAssertEqual(model.requestTreeNodes.first?.children?.first?.count, 2)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(model.selectedTransaction?.statusCode, 202)
        XCTAssertEqual(model.selectedTransaction?.responseBody, second.responseBody)
        XCTAssertEqual(model.selectedTransaction?.finishedAt, second.finishedAt)
        XCTAssertEqual(updated.last?.transaction?.responseByteCount, 8192)
        XCTAssertEqual(updated.last?.transaction?.statusCode, 202)
        XCTAssertEqual(updated.last?.transaction?.responseBody, second.responseBody)
        XCTAssertEqual(snapshot.responseBody, Data("second response".utf8))
    }

    @MainActor
    func testLeafSelectionCrossesHostAndPathWithoutChangingQueriesAndTableSelectionSharesID() async throws {
        let model = makeVM()
        let hidden = request("https://beta.test/api", method: "POST")
        let alpha = request("https://alpha.test/api")
        let betaFirst = request("https://beta.test/api")
        var betaSecond = request("https://beta.test/api")
        betaSecond.responseBody = Data("table-selected response".utf8)
        let sibling = request("https://beta.test/api/other")
        model.transactions = [hidden, alpha, betaFirst, betaSecond, sibling]
        model.searchText = " GeT "
        model.treeSearchText = " /API "
        model.selectTreeTransaction(id: alpha.id)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [alpha.id])
        XCTAssertTrue(model.treeFilteredTransactions.contains { $0.id == betaSecond.id })
        XCTAssertFalse(model.filteredTransactions.contains { $0.id == betaSecond.id })
        model.selectTreeTransaction(id: betaSecond.id)
        XCTAssertEqual(model.selectedHost, "beta.test")
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedID, betaSecond.id)
        XCTAssertEqual(model.selectedTransaction?.id, betaSecond.id)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [betaFirst.id, betaSecond.id])
        XCTAssertEqual(model.requestTreeNodes.map(\.count), [1, 3])
        XCTAssertEqual(model.searchText, " GeT ")
        XCTAssertEqual(model.treeSearchText, " /API ")
        // The right table and left leaf highlight both use the same model selection ID.
        for transaction in [betaFirst, betaSecond] {
            model.selectedID = transaction.id
            XCTAssertEqual(model.selectedTransaction?.id, transaction.id)
            XCTAssertEqual(model.selectedTransaction?.responseBody, transaction.responseBody)
            let leaves = try XCTUnwrap(model.requestTreeNodes.last?.children?.first?.children)
            XCTAssertEqual(leaves.filter { $0.transaction?.id == model.selectedID }.map(\.id.transactionID),
                           [transaction.id])
            XCTAssertEqual(model.selectedHost, "beta.test")
            XCTAssertEqual(model.selectedPath, "/api")
        }
        model.selectTreeTransaction(id: sibling.id)
        XCTAssertEqual(model.selectedHost, "beta.test")
        XCTAssertEqual(model.selectedPath, "/api/other")
        XCTAssertEqual(model.selectedID, sibling.id)
        XCTAssertEqual(model.filteredTransactions.map(\.id), [sibling.id])
        model.selectTreeTransaction(id: alpha.id)
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedTransaction?.id, alpha.id)
        XCTAssertEqual(model.searchText, " GeT ")
        XCTAssertEqual(model.treeSearchText, " /API ")
    }

    @MainActor
    func testANDSearchExcludesLeavesMaintainsCountsAndRejectsHiddenStaleAndInvalidIDs() async throws {
        let model = makeVM()
        let wrongStatus = request("https://alpha.test/api", status: 200)
        let first = request("https://alpha.test/api", status: 503)
        let second = request("https://alpha.test/api", method: "POST", status: 503)
        let sibling = request("https://alpha.test/api/other", status: 503)
        let wrongHost = request("https://beta.test/api", status: 503)
        let stale = request("https://alpha.test/api", status: 503)
        model.transactions = [wrongStatus, first, second, sibling, wrongHost, stale]
        model.searchText = " 503 "
        model.treeSearchText = " ALPHA.TEST "
        model.selectTreeTransaction(id: second.id)
        model.transactions.removeAll { $0.id == stale.id }
        XCTAssertEqual(model.treeFilteredTransactions.map(\.id), [first.id, second.id, sibling.id])
        let host = try XCTUnwrap(model.requestTreeNodes.first)
        let paths = try XCTUnwrap(host.children)
        XCTAssertEqual(model.requestTreeNodes.count, 1)
        XCTAssertEqual(paths.map(\.path), ["/api", "/api/other"])
        XCTAssertEqual(paths.map(\.count), [2, 1])
        XCTAssertEqual(host.count, 3)
        for path in paths {
            let leaves = try XCTUnwrap(path.children)
            XCTAssertEqual(path.count, leaves.count)
            XCTAssertEqual(path.count, leaves.reduce(0) { $0 + $1.count })
            XCTAssertTrue(leaves.allSatisfy { $0.transaction?.statusCode == 503 && $0.children == nil })
        }
        XCTAssertEqual(paths.flatMap { ($0.children ?? []).compactMap { $0.transaction?.id } },
                       [first.id, second.id, sibling.id])
        let treeIDs = paths.flatMap { ($0.children ?? []).map(\.id) }
        for id in [wrongStatus.id, wrongHost.id, stale.id, UUID()] {
            model.selectTreeTransaction(id: id)
            XCTAssertEqual(model.selectedHost, "alpha.test")
            XCTAssertEqual(model.selectedPath, "/api")
            XCTAssertEqual(model.selectedID, second.id)
            XCTAssertEqual(model.selectedTransaction?.id, second.id)
            XCTAssertEqual(model.filteredTransactions.map(\.id), [first.id, second.id])
            XCTAssertEqual(model.searchText, " 503 ")
            XCTAssertEqual(model.treeSearchText, " ALPHA.TEST ")
            XCTAssertEqual(model.requestTreeNodes.first?.count, 3)
            XCTAssertEqual(model.requestTreeNodes.first?.children?.flatMap { ($0.children ?? []).map(\.id) }, treeIDs)
        }
        model.searchText = "404"
        XCTAssertTrue(model.requestTreeNodes.isEmpty)
        XCTAssertTrue(model.filteredTransactions.isEmpty)
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
        model.selectTreeTransaction(id: second.id)
        XCTAssertNil(model.selectedID, "An existing capture hidden by search must not be selectable")
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.searchText, "404")
        XCTAssertEqual(model.treeSearchText, " ALPHA.TEST ")
    }

    @MainActor
    func testPrunedSelectedLeafFallsBackThroughDuplicatePathAndHostThenClearKeepsQueries() async {
        let model = makeVM()
        let hidden = request("https://alpha.test/api", method: "POST")
        let other = request("https://beta.test/api")
        let first = request("https://alpha.test/api")
        let selected = request("https://alpha.test/api")
        let sibling = request("https://alpha.test/api/other")
        model.transactions = [hidden, other, first, selected, sibling]
        model.searchText = " GET "
        model.treeSearchText = " /API "
        model.selectTreeTransaction(id: selected.id)
        XCTAssertEqual(model.selectedID, selected.id)
        model.transactions.removeAll { $0.id == selected.id }
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertEqual(model.selectedPath, "/api")
        XCTAssertEqual(model.selectedTransaction?.id, first.id, "Fallback must use the first visible duplicate, not a hidden capture")
        XCTAssertEqual(model.filteredTransactions.map(\.id), [first.id])
        XCTAssertEqual(model.requestTreeNodes.first?.count, 2)
        XCTAssertEqual(model.requestTreeNodes.first?.children?.map(\.count), [1, 1])
        model.selectTreeTransaction(id: selected.id)
        XCTAssertEqual(model.selectedID, first.id, "A pruned ID is a no-op")
        model.transactions.removeAll { $0.id == first.id }
        XCTAssertEqual(model.selectedHost, "alpha.test")
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.selectedTransaction?.id, sibling.id)
        model.transactions.removeAll { $0.id == sibling.id }
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.selectedTransaction?.id, other.id)
        model.selectTreeTransaction(id: other.id)
        XCTAssertEqual(model.selectedHost, "beta.test")
        XCTAssertEqual(model.selectedPath, "/api")
        model.clear()
        XCTAssertTrue(model.transactions.isEmpty)
        XCTAssertTrue(model.treeFilteredTransactions.isEmpty)
        XCTAssertTrue(model.filteredTransactions.isEmpty)
        XCTAssertTrue(model.requestTreeNodes.isEmpty)
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
        XCTAssertEqual(model.searchText, " GET ")
        XCTAssertEqual(model.treeSearchText, " /API ")
        model.selectTreeTransaction(id: other.id)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedHost)
        XCTAssertNil(model.selectedPath)
    }
}

nonisolated final class CustomsDNSResolverTests: XCTestCase {
    private typealias Address = CustomsSocket.Address

    /// All callback state is locked; callbacks never assert or wait while holding a lock.
    private final class LookupGate: @unchecked Sendable {
        struct Snapshot {
            let hosts: [String]
            let ports: [UInt16]
            let active: Int
            let peak: Int
        }
        private let condition = NSCondition()
        private let permits = DispatchSemaphore(value: 0)
        private var hosts: [String] = []
        private var ports: [UInt16] = []
        private var active = 0
        private var peak = 0
        let blocked: Bool
        let fails: Bool

        init(blocked: Bool = true, fails: Bool = false) {
            self.blocked = blocked
            self.fails = fails
        }

        func lookup(host: String, port: UInt16) throws -> [Address] {
            condition.lock()
            hosts.append(host); ports.append(port)
            active += 1; peak = max(peak, active)
            condition.broadcast(); condition.unlock()
            defer {
                condition.lock(); active -= 1
                condition.broadcast(); condition.unlock()
            }
            if blocked, permits.wait(timeout: .now() + 6) != .success {
                throw CustomsBackendError.message("Test lookup gate timed out")
            }
            if fails { throw CustomsBackendError.message("Injected DNS failure") }
            return [CustomsDNSResolverTests.ipv4(port: port)]
        }

        func release(_ count: Int = 1) {
            for _ in 0..<count { permits.signal() }
        }

        func waitForCalls(_ count: Int, timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock(); defer { condition.unlock() }
            while hosts.count < count {
                if !condition.wait(until: deadline) { return hosts.count >= count }
            }
            return true
        }

        var snapshot: Snapshot {
            condition.lock(); defer { condition.unlock() }
            return Snapshot(hosts: hosts, ports: ports, active: active, peak: peak)
        }
    }

    private final class Call: @unchecked Sendable {
        private let condition = NSCondition()
        private let done = DispatchSemaphore(value: 0)
        private var polls = 0
        private var cancelled = false
        private var outcome: Result<[Address], CustomsBackendError>?

        func cancellationProbe() -> Bool {
            condition.lock(); defer { condition.unlock() }
            polls += 1; condition.broadcast()
            return cancelled
        }

        func cancel() {
            condition.lock(); cancelled = true
            condition.broadcast(); condition.unlock()
        }

        /// Probe #1 precedes numeric handling; #2 precedes admission; #3 follows
        /// the first condition wait, proving the caller has entered the wait loop.
        func waitForWaitLoop(timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock(); defer { condition.unlock() }
            while polls < 3 && outcome == nil {
                if !condition.wait(until: deadline) { break }
            }
            return polls >= 3
        }

        func complete(_ result: Result<[Address], CustomsBackendError>) {
            condition.lock(); outcome = result
            condition.broadcast(); condition.unlock()
            done.signal()
        }

        func wait(timeout: TimeInterval = 3) -> Bool {
            done.wait(timeout: .now() + timeout) == .success
        }

        var result: Result<[Address], CustomsBackendError>? {
            condition.lock(); defer { condition.unlock() }
            return outcome
        }
    }

    private static func ipv4(port: UInt16) -> Address {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.7")
        return Address(bytes: withUnsafeBytes(of: &address) { Data($0) }, family: AF_INET, isLocal: true)
    }

    private func start(_ resolver: CustomsDNSResolver, host: String, port: UInt16 = 8443,
                       timeout: TimeInterval = 5) -> Call {
        let call = Call()
        // Dedicated callers cannot starve the resolver's global worker queue.
        Thread.detachNewThread {
            do {
                let addresses = try resolver.resolve(host: host, port: port, timeout: timeout,
                                                     isCancelled: { call.cancellationProbe() })
                call.complete(.success(addresses))
            } catch {
                call.complete(.failure(.message(error.localizedDescription)))
            }
        }
        return call
    }

    private func addresses(_ call: Call, file: StaticString = #filePath,
                           line: UInt = #line) throws -> [Address] {
        XCTAssertTrue(call.wait(), "Caller did not finish", file: file, line: line)
        return try XCTUnwrap(call.result, file: file, line: line).get()
    }

    private func assertFailure(_ call: Call, containing text: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(call.wait(), "Caller did not finish", file: file, line: line)
        guard case .failure(let error)? = call.result else {
            XCTFail("Expected failure containing \(text)", file: file, line: line)
            return
        }
        XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription,
                      file: file, line: line)
    }

    private func assertIPv4(_ addresses: [Address], port: UInt16,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(addresses.count, 1, file: file, line: line)
        guard let address = addresses.first else { return }
        XCTAssertEqual(address.family, AF_INET, file: file, line: line)
        XCTAssertEqual(address.bytes, Self.ipv4(port: port).bytes, file: file, line: line)
        XCTAssertTrue(address.isLocal, file: file, line: line)
    }

    private func decodedPort(_ address: Address) -> UInt16? {
        // Copy into aligned storage instead of binding potentially unaligned Data.
        if address.family == AF_INET, address.bytes.count == MemoryLayout<sockaddr_in>.size {
            var value = sockaddr_in()
            _ = withUnsafeMutableBytes(of: &value) { address.bytes.copyBytes(to: $0) }
            return UInt16(bigEndian: value.sin_port)
        }
        if address.family == AF_INET6, address.bytes.count == MemoryLayout<sockaddr_in6>.size {
            var value = sockaddr_in6()
            _ = withUnsafeMutableBytes(of: &value) { address.bytes.copyBytes(to: $0) }
            return UInt16(bigEndian: value.sin6_port)
        }
        return nil
    }

    func testMoreThanSixteenSameHostCallersShareOneLookupAndCaseInsensitiveCache() throws {
        // Repeat with fresh resolvers to exercise admission and completion transitions.
        for _ in 0..<2 {
            let gate = LookupGate()
            defer { gate.release(24) }
            let resolver = CustomsDNSResolver(lookup: { try gate.lookup(host: $0, port: $1) })
            let calls = (0..<24).map { start(resolver, host: $0.isMultiple(of: 2) ? "MiXeD.test" : "mixed.TEST") }
            XCTAssertTrue(gate.waitForCalls(1))
            for call in calls { XCTAssertTrue(call.waitForWaitLoop()) }
            XCTAssertEqual(gate.snapshot.hosts, ["mixed.test"])
            XCTAssertEqual(gate.snapshot.active, 1)
            gate.release()
            for call in calls { assertIPv4(try addresses(call), port: 8443) }
            assertIPv4(try resolver.resolve(host: "MIXED.TEST", port: 8443), port: 8443)
            XCTAssertEqual(gate.snapshot.hosts, ["mixed.test"])
            XCTAssertEqual(gate.snapshot.ports, [8443])
        }
    }

    func testDistinctKeysRespectTwoWorkersAndThreePendingWithoutAdmissionFailure() throws {
        let gate = LookupGate()
        defer { gate.release(8) }
        let resolver = CustomsDNSResolver(maximumConcurrent: 2, maximumPending: 3,
                                         lookup: { try gate.lookup(host: $0, port: $1) })
        let calls = (0..<8).map { start(resolver, host: "distinct-\($0).test") }
        XCTAssertTrue(gate.waitForCalls(2))
        for call in calls { XCTAssertTrue(call.waitForWaitLoop()) }
        // A bounded semaphore observation crosses the former one-second admission
        // failure window; no sleep or assumption about which caller was admitted.
        XCTAssertFalse(calls[0].wait(timeout: 1.1))
        XCTAssertTrue(calls.allSatisfy { $0.result == nil })
        XCTAssertEqual(gate.snapshot.hosts.count, 2)
        XCTAssertEqual(gate.snapshot.active, 2)
        gate.release(8)
        for call in calls { assertIPv4(try addresses(call), port: 8443) }
        let snapshot = gate.snapshot
        XCTAssertEqual(Set(snapshot.hosts), Set((0..<8).map { "distinct-\($0).test" }))
        XCTAssertEqual(snapshot.hosts.count, 8)
        XCTAssertEqual(snapshot.peak, 2)
        XCTAssertEqual(snapshot.active, 0)
    }

    func testNegativeCacheClearAndZeroPositiveAndNegativeTTL() throws {
        let failures = LookupGate(blocked: false, fails: true)
        let resolver = CustomsDNSResolver(lookup: { try failures.lookup(host: $0, port: $1) })
        for _ in 0..<2 {
            XCTAssertThrowsError(try resolver.resolve(host: "failure.test", port: 443)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Injected DNS failure"))
            }
        }
        XCTAssertEqual(failures.snapshot.hosts.count, 1, "Default negative TTL caches failures")
        resolver.clearCache()
        XCTAssertThrowsError(try resolver.resolve(host: "failure.test", port: 443))
        XCTAssertEqual(failures.snapshot.hosts.count, 2)

        let noNegativeCache = CustomsDNSResolver(negativeTTL: 0,
                                                lookup: { try failures.lookup(host: $0, port: $1) })
        for _ in 0..<2 { XCTAssertThrowsError(try noNegativeCache.resolve(host: "zero.test", port: 443)) }
        XCTAssertEqual(failures.snapshot.hosts.count, 4)

        let successes = LookupGate(blocked: false)
        let noPositiveCache = CustomsDNSResolver(cacheTTL: 0,
                                                lookup: { try successes.lookup(host: $0, port: $1) })
        for _ in 0..<2 { assertIPv4(try noPositiveCache.resolve(host: "zero.test", port: 443), port: 443) }
        XCTAssertEqual(successes.snapshot.hosts.count, 2)
    }

    func testCacheLimitTwoRetainsTwoEntriesAndEvictsWhenThirdIsInserted() throws {
        let gate = LookupGate(blocked: false)
        let resolver = CustomsDNSResolver(cacheLimit: 2, lookup: { try gate.lookup(host: $0, port: $1) })
        for host in ["first.test", "second.test", "first.test", "second.test"] {
            assertIPv4(try resolver.resolve(host: host, port: 443), port: 443)
        }
        XCTAssertEqual(gate.snapshot.hosts, ["first.test", "second.test"], "Two entries must fit")
        assertIPv4(try resolver.resolve(host: "third.test", port: 443), port: 443)
        XCTAssertEqual(gate.snapshot.hosts.count, 3)
        // Do not assume an eviction victim: equal Date timestamps may tie. At
        // least one of these probes must miss; subsequent probes may also evict.
        for host in ["first.test", "second.test", "third.test"] {
            assertIPv4(try resolver.resolve(host: host, port: 443), port: 443)
        }
        XCTAssertGreaterThanOrEqual(gate.snapshot.hosts.count, 4)
        XCTAssertLessThanOrEqual(gate.snapshot.hosts.count, 6)
    }

    func testTimeoutRetainsRunningCapacityAndLastCancelledQueuedWaiterIsRemoved() throws {
        let gate = LookupGate()
        defer { gate.release(4) }
        let resolver = CustomsDNSResolver(maximumConcurrent: 1, maximumPending: 1,
                                         lookup: { try gate.lookup(host: $0, port: $1) })
        let began = DispatchTime.now().uptimeNanoseconds
        let first = start(resolver, host: "running.test", timeout: 0.15)
        XCTAssertTrue(gate.waitForCalls(1))
        assertFailure(first, containing: "超时")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
        XCTAssertLessThan(elapsed, 1, "Caller deadline must not await noncancellable lookup")
        XCTAssertEqual(gate.snapshot.active, 1)

        let abandoned = start(resolver, host: "abandoned.test")
        XCTAssertTrue(abandoned.waitForWaitLoop())
        abandoned.cancel()
        assertFailure(abandoned, containing: "已取消")
        let queued = start(resolver, host: "queued.test")
        XCTAssertTrue(queued.waitForWaitLoop())
        XCTAssertFalse(gate.waitForCalls(2, timeout: 0.05))
        XCTAssertEqual(gate.snapshot.hosts, ["running.test"])
        XCTAssertNil(queued.result)
        gate.release()
        XCTAssertTrue(gate.waitForCalls(2))
        XCTAssertEqual(gate.snapshot.hosts, ["running.test", "queued.test"])
        gate.release()
        assertIPv4(try addresses(queued), port: 8443)
        XCTAssertEqual(gate.snapshot.hosts, ["running.test", "queued.test"])
        XCTAssertEqual(gate.snapshot.peak, 1)
    }

    func testCancellingOneSharedWaiterDoesNotCancelOtherWaiterOrLookup() throws {
        let gate = LookupGate()
        defer { gate.release(2) }
        let resolver = CustomsDNSResolver(lookup: { try gate.lookup(host: $0, port: $1) })
        let cancelled = start(resolver, host: "shared.test")
        XCTAssertTrue(gate.waitForCalls(1))
        let survivor = start(resolver, host: "SHARED.TEST")
        XCTAssertTrue(cancelled.waitForWaitLoop())
        XCTAssertTrue(survivor.waitForWaitLoop())
        cancelled.cancel()
        assertFailure(cancelled, containing: "已取消")
        XCTAssertFalse(survivor.wait(timeout: 0.05))
        XCTAssertEqual(gate.snapshot.hosts, ["shared.test"])
        XCTAssertEqual(gate.snapshot.active, 1)
        gate.release()
        assertIPv4(try addresses(survivor), port: 8443)
        assertIPv4(try resolver.resolve(host: "shared.test", port: 8443), port: 8443)
        XCTAssertEqual(gate.snapshot.hosts.count, 1)
    }

    func testCachedAddressesAreIsolatedByPort() throws {
        let gate = LookupGate(blocked: false)
        let resolver = CustomsDNSResolver(lookup: { try gate.lookup(host: $0, port: $1) })
        for port: UInt16 in [80, 443, 80, 443] {
            assertIPv4(try resolver.resolve(host: "ports.test", port: port), port: port)
        }
        XCTAssertEqual(gate.snapshot.hosts, ["ports.test", "ports.test"])
        XCTAssertEqual(gate.snapshot.ports, [80, 443])
    }

    func testNumericIPv4AndIPv6BypassOccupiedCapacityAndHonourCancellation() throws {
        let gate = LookupGate()
        defer { gate.release(2) }
        let resolver = CustomsDNSResolver(maximumConcurrent: 1, maximumPending: 1,
                                         lookup: { try gate.lookup(host: $0, port: $1) })
        let running = start(resolver, host: "occupied.test")
        XCTAssertTrue(gate.waitForCalls(1))
        let queued = start(resolver, host: "pending.test")
        XCTAssertTrue(queued.waitForWaitLoop())
        let ipv4 = try XCTUnwrap(resolver.resolve(host: "127.0.0.7", port: 12345, timeout: 0).first)
        assertIPv4([ipv4], port: 12345)
        XCTAssertEqual(decodedPort(ipv4), 12345)
        let ipv6 = try XCTUnwrap(resolver.resolve(host: "::1", port: 54321, timeout: 0).first)
        var expected = sockaddr_in6()
        expected.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        expected.sin6_family = sa_family_t(AF_INET6)
        expected.sin6_port = UInt16(54321).bigEndian
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &expected.sin6_addr), 1)
        XCTAssertEqual(ipv6.family, AF_INET6)
        XCTAssertEqual(ipv6.bytes, withUnsafeBytes(of: &expected) { Data($0) })
        XCTAssertEqual(decodedPort(ipv6), 54321)
        XCTAssertTrue(ipv6.isLocal)
        for host in ["127.0.0.7", "::1"] {
            XCTAssertThrowsError(try resolver.resolve(host: host, port: 443, isCancelled: { true })) { error in
                XCTAssertTrue(error.localizedDescription.contains("已取消"))
            }
        }
        XCTAssertEqual(gate.snapshot.hosts, ["occupied.test"])
        gate.release(2)
        assertIPv4(try addresses(running), port: 8443)
        assertIPv4(try addresses(queued), port: 8443)
        XCTAssertEqual(gate.snapshot.hosts, ["occupied.test", "pending.test"])
    }

    func testSystemLocalhostLookupReturnsSocketAddressesWithoutExternalNetwork() throws {
        let resolver = CustomsDNSResolver()
        let addresses = try resolver.resolve(host: "localhost", port: 43210, timeout: 5)
        XCTAssertFalse(addresses.isEmpty)
        for address in addresses {
            XCTAssertTrue(address.family == AF_INET || address.family == AF_INET6)
            XCTAssertEqual(decodedPort(address), 43210)
            if address.family == AF_INET {
                var value = sockaddr_in()
                _ = withUnsafeMutableBytes(of: &value) { address.bytes.copyBytes(to: $0) }
                XCTAssertEqual(UInt32(bigEndian: value.sin_addr.s_addr) >> 24, 127)
            } else if address.family == AF_INET6 {
                var value = sockaddr_in6()
                _ = withUnsafeMutableBytes(of: &value) { address.bytes.copyBytes(to: $0) }
                XCTAssertEqual(withUnsafeBytes(of: &value.sin6_addr) { Array($0) },
                               Array(repeating: UInt8(0), count: 15) + [1])
            }
        }
    }

    func testClearCacheDuringActiveLookupPreventsOldGenerationRepopulation() throws {
        let gate = LookupGate()
        defer { gate.release(3) }
        let resolver = CustomsDNSResolver(lookup: { try gate.lookup(host: $0, port: $1) })
        let old = start(resolver, host: "generation.test")
        XCTAssertTrue(gate.waitForCalls(1))
        resolver.clearCache()
        gate.release()
        assertIPv4(try addresses(old), port: 8443)
        // Caller completion occurs after the worker's cache update, so this next
        // lookup must miss rather than depend on a delay after clearCache().
        let fresh = start(resolver, host: "GENERATION.TEST")
        XCTAssertTrue(gate.waitForCalls(2))
        gate.release()
        assertIPv4(try addresses(fresh), port: 8443)
        assertIPv4(try resolver.resolve(host: "generation.test", port: 8443), port: 8443)
        XCTAssertEqual(gate.snapshot.hosts, ["generation.test", "generation.test"])
    }
}

nonisolated final class CustomsSocketDialTests: XCTestCase {
    private enum RegistrationError: Error { case cancelledSession }

    private final class DialState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var phases: [CustomsSocket.ConnectionPhase] = []
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func record(_ phase: CustomsSocket.ConnectionPhase) {
            lock.lock(); defer { lock.unlock() }; phases.append(phase)
        }
        var phaseNames: [String] {
            lock.lock(); defer { lock.unlock() }
            return phases.map { switch $0 { case .dns: return "dns"; case .connecting: return "connecting" } }
        }
    }

    private func address(_ host: String = "127.0.0.1", port: UInt16) throws -> CustomsSocket.Address {
        try XCTUnwrap(CustomsDNSResolver().resolve(host: host, port: port).first)
    }

    /// A bound but non-listening TCP endpoint silently drops loopback SYNs on
    /// the tested Darwin/macOS 26 stack. This is a pending-dial fixture, NOT a
    /// portable ECONNREFUSED fixture. Tests below fail (never skip) if Darwin's
    /// behavior changes, so a fast RST cannot masquerade as pending coverage.
    private func pendingSocket() throws -> CustomsSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CustomsBackendError.system("test socket") }
        let socket = try CustomsSocket(fd)
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw CustomsBackendError.system("test bind") }
        return socket
    }

    /// Release a real ephemeral listener before dialing its port, producing a
    /// loopback RST rather than Darwin's bound-without-listen SYN drop. As with
    /// ordinary reserve-port fixtures, another process could rebind this port.
    private func closedListenerPort() throws -> UInt16 {
        var listener: CustomsSocket? = try CustomsSocket.listen(port: 0, lan: false)
        let port = try XCTUnwrap(listener).localPort
        listener = nil // deinit closes the descriptor; cancel alone would retain it.
        return port
    }

    private func assertConnected(_ socket: CustomsSocket, port: UInt16,
                                 file: StaticString = #filePath, line: UInt = #line) {
        var peer = sockaddr_in()
        var size = socklen_t(MemoryLayout.size(ofValue: peer))
        let result = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(socket.descriptor, $0, &size)
            }
        }
        XCTAssertEqual(result, 0, file: file, line: line)
        XCTAssertEqual(UInt16(bigEndian: peer.sin_port), port, file: file, line: line)
        XCTAssertFalse(socket.isCancelled, file: file, line: line)
    }

    func testIPv6PreferenceInterleavesFamiliesAndPreservesFamilyOrder() throws {
        let v6a = try address("::1", port: 1), v6b = try address("::1", port: 2)
        let v4a = try address(port: 3), v4b = try address(port: 4), v4c = try address(port: 5)
        let output = CustomsSocket.interleavedAddresses([v6a, v6b, v4a, v4b, v4c])
        XCTAssertEqual(output.map(\.family), [AF_INET6, AF_INET, AF_INET6, AF_INET, AF_INET])
        XCTAssertEqual(output.map(\.bytes), [v6a, v4a, v6b, v4b, v4c].map(\.bytes))
    }

    func testIPv4PreferenceSingleFamilyAndEmptyInterleave() throws {
        let v4a = try address(port: 1), v4b = try address(port: 2)
        let v6a = try address("::1", port: 3), v6b = try address("::1", port: 4)
        XCTAssertEqual(CustomsSocket.interleavedAddresses([v4a, v4b, v6a, v6b]).map(\.bytes),
                       [v4a, v6a, v4b, v6b].map(\.bytes))
        XCTAssertEqual(CustomsSocket.interleavedAddresses([v4a, v4b]).map(\.bytes), [v4a.bytes, v4b.bytes])
        XCTAssertTrue(CustomsSocket.interleavedAddresses([]).isEmpty)
    }

    func testRefusedFirstCandidateImmediatelyFallsBackAndCancelsRetainedLoser() throws {
        let listener = try CustomsSocket.listen(port: 0, lan: false)
        defer { listener.cancel() }
        let refusedPort = try closedListenerPort()
        let candidates = try [address(port: refusedPort), address(port: listener.localPort)]
        var registered: [CustomsSocket] = []
        let began = ProcessInfo.processInfo.systemUptime
        // Five seconds makes waiting for the stagger on a concrete refusal observable.
        let connected = try CustomsSocket.connect(addresses: candidates, host: "fallback.test",
                                                  port: listener.localPort, fallbackDelay: 5) { registered.append($0) }
        defer { connected.cancel() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertEqual(registered.count, 2)
        guard registered.count == 2 else { return }
        XCTAssertTrue(registered[0].isCancelled)
        XCTAssertTrue(registered[1] === connected)
        assertConnected(connected, port: listener.localPort)
        let accepted = try XCTUnwrap(listener.acceptClient())
        defer { accepted.cancel() }
        XCTAssertThrowsError(try CustomsPlainTransport(registered[0]).write(Data([1])))
        XCTAssertGreaterThanOrEqual(fcntl(registered[0].descriptor, F_GETFD), 0,
                                    "A retained loser must be shut down, not prematurely closed")
    }

    func testAllRefusedCandidatesReportHostPortAndConcreteErrnoAndCancelEverySocket() throws {
        let firstPort = try closedListenerPort(), lastPort = try closedListenerPort()
        let candidates = try [address(port: firstPort), address(port: lastPort)]
        var registered: [CustomsSocket] = []
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: candidates, host: "refused.test",
                                                       port: lastPort) { registered.append($0) }) { error in
            XCTAssertTrue(error.localizedDescription.contains("refused.test:\(lastPort)"))
            XCTAssertTrue(error.localizedDescription.contains("errno=\(ECONNREFUSED)"), error.localizedDescription)
        }
        XCTAssertEqual(registered.count, 2)
        XCTAssertTrue(registered.allSatisfy { $0.isCancelled })
    }

    func testPendingFirstCandidateStaggersToListenerWithoutCancellingOlderAttempt() throws {
        let pending = try pendingSocket()
        let listener = try CustomsSocket.listen(port: 0, lan: false)
        defer { pending.cancel(); listener.cancel() }
        let candidates = try [address(port: pending.localPort), address(port: listener.localPort)]
        var registered: [CustomsSocket] = []
        var firstWasLiveAtSecondRegistration = false
        let began = ProcessInfo.processInfo.systemUptime
        // Use production's default 250ms delay. No timing lower bound: prove
        // overlap directly, rather than relying on scheduler timing precision.
        let connected = try CustomsSocket.connect(addresses: candidates, host: "pending.test",
                                                  port: listener.localPort) { socket in
            if let first = registered.first {
                firstWasLiveAtSecondRegistration = !first.isCancelled
                XCTAssertFalse(first.isCancelled, "Stagger must not shut down the older inflight attempt")
                XCTAssertGreaterThanOrEqual(fcntl(first.descriptor, F_GETFD), 0)
            }
            registered.append(socket)
        }
        defer { connected.cancel() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5)
        XCTAssertEqual(registered.count, 2)
        XCTAssertTrue(firstWasLiveAtSecondRegistration,
                      "Darwin fixture must remain pending; an immediate RST is not overlap coverage")
        guard registered.count == 2 else { return }
        XCTAssertTrue(registered[0].isCancelled, "Winner return must clean up the pending loser")
        XCTAssertTrue(registered[1] === connected)
        for socket in registered {
            XCTAssertGreaterThanOrEqual(fcntl(socket.descriptor, F_GETFD), 0,
                                        "Both retained objects must still own their descriptors")
        }
        XCTAssertThrowsError(try CustomsPlainTransport(registered[0]).write(Data([1])))
        assertConnected(connected, port: listener.localPort)
        let accepted = try XCTUnwrap(listener.acceptClient())
        accepted.cancel()
    }

    func testCancellationDuringPendingPollCleansUpBeforeFallbackOrTenSecondDeadline() throws {
        let pending = try pendingSocket()
        let listener = try CustomsSocket.listen(port: 0, lan: false)
        defer { pending.cancel(); listener.cancel() }
        let candidates = try [address(port: pending.localPort), address(port: listener.localPort)]
        let state = DialState()
        var registered: [CustomsSocket] = []
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: candidates, host: "poll-cancel.test",
                                                       port: listener.localPort, timeout: 10, fallbackDelay: 5,
                                                       isCancelled: { state.isCancelled }) { socket in
            registered.append(socket)
            // Registration returns immediately; cancellation happens while the
            // caller is polling the nonblocking connection, not in register.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                state.cancel()
            }
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("已取消"), error.localizedDescription)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5)
        XCTAssertEqual(registered.count, 1, "Cancellation must precede the five-second fallback")
        XCTAssertTrue(registered.allSatisfy { $0.isCancelled })
        for socket in registered {
            XCTAssertGreaterThanOrEqual(fcntl(socket.descriptor, F_GETFD), 0)
            XCTAssertThrowsError(try CustomsPlainTransport(socket).write(Data([1])))
        }
        XCTAssertNil(try listener.acceptClient())
    }

    func testShortGlobalDeadlineDuringPendingPollCancelsAllInflightSockets() throws {
        let pending = try pendingSocket()
        defer { pending.cancel() }
        let candidate = try address(port: pending.localPort)
        var registered: [CustomsSocket] = []
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [candidate], host: "poll-deadline.test",
                                                       port: pending.localPort, timeout: 0.12) { registered.append($0) }) { error in
            XCTAssertTrue(error.localizedDescription.contains("poll-deadline.test:\(pending.localPort)"))
            XCTAssertTrue(error.localizedDescription.contains("超时"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("errno=\(ETIMEDOUT)"), error.localizedDescription)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertEqual(registered.count, 1)
        XCTAssertTrue(registered.allSatisfy { $0.isCancelled })
        for socket in registered {
            XCTAssertGreaterThanOrEqual(fcntl(socket.descriptor, F_GETFD), 0)
            XCTAssertThrowsError(try CustomsPlainTransport(socket).write(Data([1])))
        }
    }

    func testRegistrationErrorPropagatesWithoutTryingNextCandidate() throws {
        let listener = try CustomsSocket.listen(port: 0, lan: false)
        defer { listener.cancel() }
        let candidate = try address(port: listener.localPort)
        var registered: [CustomsSocket] = []
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [candidate, candidate], host: "register.test",
                                                       port: listener.localPort) {
            registered.append($0)
            throw RegistrationError.cancelledSession
        }) { error in
            guard case RegistrationError.cancelledSession = error else {
                return XCTFail("Registration error was swallowed: \(error)")
            }
        }
        XCTAssertEqual(registered.count, 1)
        XCTAssertTrue(registered.allSatisfy { $0.isCancelled })
        XCTAssertNil(try listener.acceptClient(), "Register must happen before connect")
    }

    func testPreCancelledDialDoesNotRegisterOrSpendTenSeconds() throws {
        let candidate = try address(port: 1)
        var registrations = 0
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [candidate], host: "cancel.test", port: 1,
                                                       isCancelled: { true }) { _ in registrations += 1 }) { error in
            XCTAssertTrue(error.localizedDescription.contains("已取消"))
        }
        XCTAssertEqual(registrations, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
    }

    func testSessionCancellationAfterRegistrationCancelsCandidateBeforeConnect() throws {
        let listener = try CustomsSocket.listen(port: 0, lan: false)
        defer { listener.cancel() }
        let candidate = try address(port: listener.localPort)
        let state = DialState()
        var registered: [CustomsSocket] = []
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [candidate, candidate], host: "cancel.test",
                                                       port: listener.localPort, isCancelled: { state.isCancelled }) {
            registered.append($0); state.cancel()
        }) { error in XCTAssertTrue(error.localizedDescription.contains("已取消")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
        XCTAssertEqual(registered.count, 1)
        XCTAssertTrue(registered.allSatisfy { $0.isCancelled })
        XCTAssertNil(try listener.acceptClient())
    }

    func testSocketCancellationDuringRegistrationIsTerminalEvenWithoutSessionFlag() throws {
        let candidate = try address(port: 1)
        var registered: [CustomsSocket] = []
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [candidate, candidate], host: "cancel.test", port: 1) {
            registered.append($0); $0.cancel()
        }) { error in XCTAssertTrue(error.localizedDescription.contains("已取消")) }
        XCTAssertEqual(registered.count, 1)
        XCTAssertTrue(registered.allSatisfy { $0.isCancelled })
    }

    func testExpiredGlobalDeadlineDoesNotStartAnyCandidate() throws {
        let candidate = try address(port: 1)
        var registrations = 0
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [candidate, candidate], host: "deadline.test", port: 1,
                                                       timeout: 0) { _ in registrations += 1 }) { error in
            XCTAssertTrue(error.localizedDescription.contains("deadline.test:1"))
            XCTAssertTrue(error.localizedDescription.contains("errno=\(ETIMEDOUT)"))
        }
        XCTAssertEqual(registrations, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
    }

    func testDeadlineExpiringDuringRegistrationCancelsSocketWithoutStartingConnect() throws {
        let listener = try CustomsSocket.listen(port: 0, lan: false)
        defer { listener.cancel() }
        let candidate = try address(port: listener.localPort)
        var retained: CustomsSocket?
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [candidate, candidate], host: "deadline.test",
                                                       port: listener.localPort, timeout: 0.01) {
            retained = $0
            // Exercise the post-registration deadline check deterministically,
            // without relying on an external blackhole or a full listen backlog.
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.03)
        }) { error in XCTAssertTrue(error.localizedDescription.contains("errno=\(ETIMEDOUT)")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
        XCTAssertTrue(try XCTUnwrap(retained).isCancelled)
        XCTAssertNil(try listener.acceptClient())
    }

    func testMalformedLastCandidateReportsItsErrorAndCancelsRegisteredSocket() throws {
        let malformed = CustomsSocket.Address(bytes: Data(), family: AF_INET, isLocal: true)
        var retained: CustomsSocket?
        XCTAssertThrowsError(try CustomsSocket.connect(addresses: [malformed], host: "invalid.test", port: 443) {
            retained = $0
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid.test:443"))
            XCTAssertTrue(error.localizedDescription.contains("errno=\(EINVAL)"))
        }
        XCTAssertTrue(try XCTUnwrap(retained).isCancelled)
    }

    func testNumericConnectEmitsDNSThenConnectingAndSupportsOldTrailingRegister() throws {
        let listener = try CustomsSocket.listen(port: 0, lan: false)
        defer { listener.cancel() }
        let state = DialState()
        let first = try CustomsSocket.connect(host: "127.0.0.1", port: listener.localPort, proxyPort: 0,
                                              onPhase: { state.record($0) }) { _ in }
        defer { first.cancel() }
        XCTAssertEqual(state.phaseNames, ["dns", "connecting"])
        assertConnected(first, port: listener.localPort)
        let second = try CustomsSocket.connect(host: "127.0.0.1", port: listener.localPort, proxyPort: 0) { _ in }
        defer { second.cancel() }
        assertConnected(second, port: listener.localPort)
    }

    func testSamePortRejectionOccursBeforeDNSPhaseOrRegistration() {
        let state = DialState()
        var registrations = 0
        XCTAssertThrowsError(try CustomsSocket.connect(host: "never-resolve.invalid", port: 443, proxyPort: 443,
                                                       onPhase: { state.record($0) }) { _ in registrations += 1 }) { error in
            XCTAssertTrue(error.localizedDescription.contains("防止循环"))
        }
        XCTAssertTrue(state.phaseNames.isEmpty)
        XCTAssertEqual(registrations, 0)
    }
}

nonisolated final class CustomConnectPresentationTests: XCTestCase {
    private func connect(policy: CustomsHTTPSHandling?, phase: CustomsRequestPhase,
                         error: String? = nil, relatedID: UUID? = nil,
                         finished: Bool = true) -> CustomsTransaction {
        let start = Date(timeIntervalSince1970: 100)
        var transaction = CustomsTransaction(startedAt: start, method: "CONNECT", url: "https://example.test:443")
        transaction.isTunnel = true
        transaction.httpsHandling = policy
        transaction.relatedTransactionID = relatedID
        let phases: [CustomsRequestPhase] = phase == .tunnel ? [.captured, .dns, .connecting, .tunnel] :
            [.captured, .dns, .connecting, .certificate, .upstreamTLS, .clientTLS, .clientRequest]
        for (index, next) in phases.enumerated() {
            transaction.advance(to: next, at: start.addingTimeInterval(Double(index)))
            if next == phase { break }
        }
        if [.tunnel, .clientTLS, .clientRequest].contains(phase) { transaction.statusCode = 200 }
        transaction.error = error
        if finished { transaction.finishTiming(at: start.addingTimeInterval(10)) }
        return transaction
    }

    func testLegacyUnknownPolicyDoesNotInventDisabledReason() {
        let transaction = connect(policy: nil, phase: .tunnel)
        XCTAssertNil(transaction.httpsHandling)
        XCTAssertNil(transaction.relatedTransactionID)
        XCTAssertTrue(transaction.connectNotice.contains("没有保存解密配置"))
        XCTAssertTrue(transaction.connectNotice.contains("不能判断"))
        XCTAssertFalse(transaction.connectNotice.contains(CustomsHTTPSHandling.disabled.title))
        XCTAssertFalse(transaction.connectNotice.contains(CustomsHTTPSHandling.hostExcluded.title))
    }

    func testDisabledPolicyExplainsStartupChoiceAndCannotRetroactivelyDecrypt() {
        let transaction = connect(policy: .disabled, phase: .tunnel)
        let notice = transaction.connectNotice
        XCTAssertTrue(notice.contains("关闭了 HTTPS 解密"))
        XCTAssertTrue(notice.contains("仅转发加密"))
        XCTAssertTrue(notice.contains("停止代理"))
        XCTAssertTrue(notice.contains("不会补解密"))
        XCTAssertFalse(notice.contains(CustomsHTTPSHandling.hostExcluded.title))
    }

    func testExcludedHostExplainsSSLRangeRatherThanDisabledSwitch() {
        let transaction = connect(policy: .hostExcluded, phase: .tunnel)
        XCTAssertTrue(transaction.connectNotice.contains("目标域名不在 SSL 解密范围"))
        XCTAssertTrue(transaction.connectNotice.contains("域名范围匹配"))
        XCTAssertFalse(transaction.connectNotice.contains(CustomsHTTPSHandling.disabled.title))
    }

    func testClientTLSResetPreservesFailureDespite200AndOnlySuggestsPinning() throws {
        let error = "CONNECT example.test · 客户端 TLS 握手失败：客户端 TLS socket 读取失败: Connection reset by peer (errno=54)"
        let transaction = connect(policy: .decrypting, phase: .clientTLS, error: error)
        XCTAssertEqual(transaction.phase, .clientTLS)
        XCTAssertEqual(transaction.statusCode, 200)
        XCTAssertNotNil(transaction.finishedAt)
        XCTAssertNotNil(try XCTUnwrap(transaction.phaseTimings.last).finishedAt)
        let notice = transaction.connectNotice
        XCTAssertTrue(notice.contains(CustomsRequestPhase.clientTLS.title))
        XCTAssertTrue(notice.contains(error))
        XCTAssertTrue(notice.contains("可能"))
        XCTAssertTrue(notice.contains("证书绑定"))
        XCTAssertTrue(notice.contains("不能仅凭连接重置认定 CA 未信任"))
        XCTAssertTrue(notice.contains("不代表 HTTPS 请求成功"))
        XCTAssertFalse(notice.contains("请点击「查看解密后的请求」"))
        XCTAssertFalse(transaction.canCopyCurl)
        XCTAssertNil(transaction.curl())
    }

    func testUpstreamTLSFailureExplainsIPhoneCATrustIsIrrelevant() {
        let error = "上游 TLS 握手失败：socket 读取失败: Connection reset by peer"
        let transaction = connect(policy: .decrypting, phase: .upstreamTLS, error: error)
        XCTAssertEqual(transaction.phase, .upstreamTLS)
        XCTAssertNil(transaction.statusCode)
        XCTAssertTrue(transaction.connectNotice.contains(CustomsRequestPhase.upstreamTLS.title))
        XCTAssertTrue(transaction.connectNotice.contains(error))
        XCTAssertTrue(transaction.connectNotice.contains("与 iPhone 是否信任代理 CA 无关"))
        XCTAssertTrue(transaction.connectNotice.contains("源站证书"))
    }

    func testClientRequestFailureAcknowledgesBothTLSHandshakesCompleted() {
        let transaction = connect(policy: .decrypting, phase: .clientRequest, error: "客户端未发送 HTTP 请求")
        XCTAssertEqual(transaction.phase, .clientRequest)
        XCTAssertTrue(transaction.connectNotice.contains("两端 TLS 握手已完成"))
        XCTAssertTrue(transaction.connectNotice.contains("未拿到可解析的客户端 HTTP 请求"))
        XCTAssertTrue(transaction.connectNotice.contains("不代表 HTTPS 请求成功"))
        XCTAssertFalse(transaction.connectNotice.contains("客户端 TLS 握手未完成"))
    }

    func testSuccessfulRelatedCONNECTGuidesToHTTPRecordRatherThanRepeatedSetup() {
        let relatedID = UUID()
        let transaction = connect(policy: .decrypting, phase: .clientRequest, relatedID: relatedID)
        XCTAssertEqual(transaction.phase, .completed)
        XCTAssertNil(transaction.error)
        XCTAssertEqual(transaction.relatedTransactionID, relatedID)
        XCTAssertTrue(transaction.connectNotice.contains("真实 HTTP 请求已生成关联记录"))
        XCTAssertTrue(transaction.connectNotice.contains("请点击「查看解密后的请求」"))
        XCTAssertTrue(transaction.connectNotice.contains("不需要重复开启解密或安装证书"))
        let pending = connect(policy: .decrypting, phase: .clientRequest, finished: false)
        XCTAssertNil(pending.finishedAt)
        XCTAssertTrue(pending.connectNotice.contains("尚未生成独立记录"))
        XCTAssertFalse(pending.connectNotice.contains("请点击「查看解密后的请求」"))
    }

    func testCompletedDecryptingCONNECTWithoutRecordedHTTPExplainsPausedRecording() {
        let transaction = connect(policy: .decrypting, phase: .clientRequest)
        XCTAssertNil(transaction.relatedTransactionID)
        XCTAssertTrue(transaction.connectNotice.contains("关联 HTTP 请求未录制"))
        XCTAssertTrue(transaction.connectNotice.contains("录制已暂停"))
        XCTAssertFalse(transaction.connectNotice.contains("尚未生成独立记录"))
        XCTAssertFalse(transaction.connectNotice.contains("请点击「查看解密后的请求」"))
    }

    func testNonCONNECTUpgradeCannotMasqueradeAsSuccessfulDecryption() {
        var transaction = connect(policy: .decrypting, phase: .clientRequest, relatedID: UUID())
        transaction.method = "GET"
        transaction.requestHeaders = [CustomsHeader(name: "Upgrade", value: "websocket")]
        XCTAssertTrue(transaction.isTunnel)
        XCTAssertTrue(transaction.connectNotice.contains("不是普通 HTTP 正文记录"))
        XCTAssertTrue(transaction.connectNotice.contains("不会被当作 CONNECT 解密成功"))
        XCTAssertFalse(transaction.connectNotice.contains("请点击「查看解密后的请求」"))
    }
}
