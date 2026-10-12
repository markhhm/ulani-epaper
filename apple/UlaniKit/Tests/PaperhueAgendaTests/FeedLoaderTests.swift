import Foundation
import Testing
@testable import PaperhueAgenda

/// Answers the loader's requests in-process, so no request reaches the network: replies are
/// registered by full address, and every request that arrives is recorded.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case body(status: Int, headers: [String: String], chunks: [Data])
        case redirect(status: Int, to: String)
        case failure(URLError.Code, failingURL: String)
        /// Never answers (until the task is cancelled).
        case silence
    }

    private final class Table: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: Reply] = [:]
        var seen: [URLRequest] = []
    }

    private static let table = Table()

    static func register(_ url: String, _ reply: Reply) {
        table.lock.withLock { table.replies[url] = reply }
    }

    /// The requests that arrived for `host`, in order.
    static func requests(to host: String) -> [URLRequest] {
        table.lock.withLock { table.seen.filter { $0.url?.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let reply = Self.table.lock.withLock { () -> Reply? in
            Self.table.seen.append(request)
            return Self.table.replies[url.absoluteString]
        }
        switch reply ?? .failure(.cannotFindHost, failingURL: url.absoluteString) {
        case .body(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client.urlProtocol(self, didLoad: chunk) }
            client.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let target):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target])!
            var next = URLRequest(url: URL(string: target)!)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields  // as an HTTP loader carries them over
            client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case .failure(let code, let failingURL):
            client.urlProtocol(self, didFailWithError: URLError(code, userInfo: [
                NSURLErrorFailingURLStringErrorKey: failingURL, NSURLErrorFailingURLErrorKey: URL(string: failingURL)!,
            ]))
        case .silence:
            break
        }
    }

    override func stopLoading() {}
}

/// A loader whose requests the stub answers.
private func stubbedLoader() -> URLSessionFeedLoader {
    URLSessionFeedLoader(userAgent: "Paperhue/test", protocolClasses: [StubProtocol.self])
}

private let calendar = Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)

/// A unique https address on a host of its own (tests run side by side).
private func address(_ path: String = "cal.ics") -> String { "https://\(UUID().uuidString.lowercased()).test/\(path)" }

/// Every text of `error`, including Foundation's user info.
private func texts(_ error: (any Error)?) -> [String] {
    guard let error else { return [] }
    return [String(describing: error), String(reflecting: error), error.localizedDescription,
            "\((error as NSError).userInfo)"]
}

/// python/tests/test_feeds.py's download tests, against a real URLSession whose requests are
/// answered in-process (StubProtocol), and the redirect and error rules on their own.
@Suite struct FeedLoaderTests {
    @Test func sendsAPlainGetWithBasicAuthWhenGiven() async throws {
        let url = address()
        StubProtocol.register(url, .body(status: 200, headers: [:], chunks: [calendar]))
        let body = try await stubbedLoader().load(url, user: "me", password: "pw")
        #expect(body == calendar)
        let request = try #require(StubProtocol.requests(to: URL(string: url)!.host!).first)
        #expect(request.url?.absoluteString == url && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic bWU6cHc=")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Paperhue/test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/calendar, */*")
        #expect(request.timeoutInterval == 30)
    }

    @Test func withoutCredentialsNoAuthorizationIsSent() async throws {
        let url = address()
        StubProtocol.register(url, .body(status: 200, headers: [:], chunks: [calendar]))
        _ = try await stubbedLoader().load(url, user: "", password: "")
        let request = try #require(StubProtocol.requests(to: URL(string: url)!.host!).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func theDefaultUserAgentNamesTheApp() {
        #expect(URLSessionFeedLoader.defaultUserAgent.hasPrefix("Paperhue"))
        #expect(URLSessionFeedLoader().userAgent == URLSessionFeedLoader.defaultUserAgent)
    }

    // MARK: Redirects

    @Test func credentialsAreNotSentOnToARedirect() async throws {
        let (from, to) = (address("a.ics"), address("b.ics"))
        StubProtocol.register(from, .redirect(status: 302, to: to))
        StubProtocol.register(to, .body(status: 200, headers: [:], chunks: [calendar]))
        #expect(try await stubbedLoader().load(from, user: "me", password: "pw") == calendar)
        let first = try #require(StubProtocol.requests(to: URL(string: from)!.host!).first)
        let second = try #require(StubProtocol.requests(to: URL(string: to)!.host!).first)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Basic bWU6cHc=")
        #expect(second.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(second.value(forHTTPHeaderField: "User-Agent") == "Paperhue/test")
    }

    @Test func aRedirectFromHTTPSToHTTPIsRefused() async {
        let from = address()
        let to = from.replacingOccurrences(of: "https://", with: "http://") + "-plain"
        StubProtocol.register(from, .redirect(status: 302, to: to))
        StubProtocol.register(to, .body(status: 200, headers: [:], chunks: [calendar]))
        let error = await thrown { _ = try await stubbedLoader().load(from, user: "", password: "") }
        #expect(error as? FeedError == .http(status: 302))  // as Python's urllib reports it
        #expect(StubProtocol.requests(to: URL(string: from)!.host!).count == 1)  // the plain address never asked
    }

    @Test func theRedirectRules() throws {
        let secure = URL(string: "https://example.com/a.ics")
        var request = URLRequest(url: URL(string: "https://example.org/a.ics")!)
        request.setValue("Basic bWU6cHc=", forHTTPHeaderField: "Authorization")
        request.setValue("Paperhue/test", forHTTPHeaderField: "User-Agent")
        var visited: [String: Int] = [:]
        let followed = try URLSessionFeedLoader.redirect(from: secure, status: 301, to: request, visited: &visited).get()
        #expect(followed.url == request.url && followed.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(followed.value(forHTTPHeaderField: "User-Agent") == "Paperhue/test")

        for target in ["http://example.com/a.ics", "ftp://example.com/a.ics", "file:///etc/passwd"] {
            var plain = URLRequest(url: URL(string: target)!)
            plain.setValue("x", forHTTPHeaderField: "Accept")
            var none: [String: Int] = [:]
            let refused = URLSessionFeedLoader.redirect(from: secure, status: 302, to: plain, visited: &none)
            #expect(throws: FeedError.http(status: 302)) { try refused.get() }
        }
        var down = URLRequest(url: URL(string: "http://example.com/b.ics")!)
        down.httpMethod = "GET"
        var none: [String: Int] = [:]
        #expect(throws: Never.self) {  // http -> http is allowed, as Python allows it
            try URLSessionFeedLoader.redirect(from: URL(string: "http://example.com/a.ics"), status: 302, to: down,
                                              visited: &none).get()
        }
    }

    @Test func redirectLoopsStopAsPythonStopsThem() {
        // Python's HTTPRedirectHandler: at most 4 visits to one address, at most 10 addresses
        var visited: [String: Int] = [:]
        let same = URLRequest(url: URL(string: "https://example.com/loop")!)
        let outcomes = (0..<5).map { _ in
            (try? URLSessionFeedLoader.redirect(from: same.url, status: 302, to: same, visited: &visited).get()) != nil
        }
        #expect(outcomes == [true, true, true, true, false])
        visited = [:]
        let distinct = (0..<11).map { i in
            let next = URLRequest(url: URL(string: "https://example.com/\(i)")!)
            return (try? URLSessionFeedLoader.redirect(from: same.url, status: 307, to: next, visited: &visited).get()) != nil
        }
        #expect(distinct == Array(repeating: true, count: 10) + [false])
    }

    // MARK: Size

    @Test func hugeFeedsAreRefusedWhileStreaming() async {
        let url = address()
        let mebibyte = Data(repeating: 0x78, count: 1024 * 1024)
        StubProtocol.register(url, .body(status: 200, headers: [:], chunks: Array(repeating: mebibyte, count: 21)))
        let error = await thrown { _ = try await stubbedLoader().load(url, user: "", password: "") }
        #expect(error as? FeedError == .tooLarge)
        #expect("\(error!)".contains("MB"))
    }

    @Test func exactlyTheLimitIsRead() async throws {
        let url = address()
        let mebibyte = Data(repeating: 0x78, count: 1024 * 1024)
        StubProtocol.register(url, .body(status: 200, headers: [:], chunks: Array(repeating: mebibyte, count: 20)))
        #expect(try await stubbedLoader().load(url, user: "", password: "").count == Feeds.maxBytes)
    }

    @Test func aDeclaredLengthOverTheLimitIsRefusedAtOnce() async {
        let url = address()
        StubProtocol.register(url, .body(status: 200, headers: ["Content-Length": "\(Feeds.maxBytes + 1)"],
                                         chunks: [calendar]))
        let error = await thrown { _ = try await stubbedLoader().load(url, user: "", password: "") }
        #expect(error as? FeedError == .tooLarge)
    }

    // MARK: Errors

    @Test(arguments: [(404, "404"), (400, "重設"), (401, "401"), (403, "沒有權限"), (500, "伺服器拒絕")])
    func httpErrorsNeverShowTheSecretAddress(status: Int, phrase: String) async {
        StubProtocol.register(secretAddress, .body(status: status, headers: [:], chunks: [Data("denied".utf8)]))
        let error = await thrown { _ = try await stubbedLoader().load(secretAddress, user: "", password: "") }
        #expect(error as? FeedError == .http(status: status))
        #expect("\(error!)".contains(phrase))
        for text in texts(error) { #expect(!text.contains("private-") && !text.contains("me%40gmail")) }
    }

    @Test(arguments: [URLError.Code.cannotFindHost, .timedOut, .notConnectedToInternet, .secureConnectionFailed])
    func connectionErrorsNameOnlyTheHost(code: URLError.Code) async {
        let url = secretAddress + "?\(code.rawValue)"
        StubProtocol.register(url, .failure(code, failingURL: url))
        let error = await thrown { _ = try await stubbedLoader().load(url, user: "", password: "") }
        let expected = FeedError.cannotConnect(host: "calendar.google.com", reason: URLSessionFeedLoader.name(of: code))
        #expect(error as? FeedError == expected)
        #expect("\(error!)".contains("連線") && "\(error!)".contains("calendar.google.com"))
        for text in texts(error) { #expect(!text.contains("private-") && !text.contains("me%40gmail")) }
    }

    @Test func anAddressFoundationCannotLoadIsNotRepeated() async {
        let error = await thrown {
            _ = try await stubbedLoader().load("https://calendar.google.com:abc/private-x/basic.ics", user: "", password: "")
        }
        #expect(error as? FeedError == .cannotConnect(host: "calendar.google.com", reason: "InvalidURL"))
    }

    @Test func transferErrorsMapLikePythonsDownload() {
        func mapped(_ code: URLError.Code) -> FeedError? {
            URLSessionFeedLoader.feedError(URLError(code), host: "h") as? FeedError
        }
        #expect(mapped(.cannotDecodeContentData) == .damagedCompression)
        #expect(mapped(.cannotDecodeRawData) == .damagedCompression)
        #expect(mapped(.dataLengthExceedsMaximum) == .tooLarge)
        #expect(mapped(.timedOut) == .cannotConnect(host: "h", reason: "timedOut"))
        #expect(mapped(.backgroundSessionWasDisconnected) == .cannotConnect(host: "h", reason: "URLError -997"))
        #expect(URLSessionFeedLoader.feedError(URLError(.cancelled), host: "h") is CancellationError)
        #expect(FeedError.damagedCompression.description == "收到損壞的壓縮資料")
    }

    @Test func cancellingTheTaskCancelsTheDownload() async {
        let url = address()
        StubProtocol.register(url, .silence)
        let loader = stubbedLoader()
        let task = Task { try await loader.load(url, user: "", password: "") }
        while StubProtocol.requests(to: URL(string: url)!.host!).isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let error = await thrown { _ = try await task.value }
        #expect(error is CancellationError)
    }
}
