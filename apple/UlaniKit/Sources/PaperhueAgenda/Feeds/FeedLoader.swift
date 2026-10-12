import Foundation

/// Downloads one feed's body (Python: `feeds.download`). Tests use their own.
public protocol FeedLoader: Sendable {
    /// The body at `url` (a normalized address), sent with HTTP Basic credentials when `user`
    /// or `password` is not empty. Throws a `FeedError` that does not contain the address, or
    /// `CancellationError`.
    func load(_ url: String, user: String, password: String) async throws -> Data
}

/// The `FeedLoader` of the app: one ephemeral `URLSession` that keeps nothing (no cache, no
/// cookies, no credentials) and holds the body in memory only.
///
/// A GET with User-Agent and Accept, and Authorization (Basic) when a login is given; 30 s
/// for the server to answer; at most `Feeds.maxBytes`, checked while the body streams in.
/// Redirects are followed, but never from https down to http (the path is the secret), at
/// most 10 of them and 4 to the same address, and the Authorization header is not sent on to
/// the redirect target. Every failure becomes a `FeedError` naming only the host:
/// `URLError` and its `failingURL` never leave this type.
public final class URLSessionFeedLoader: FeedLoader {
    /// "Paperhue/<the app's version>" ("Paperhue" outside an app bundle).
    public static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Paperhue/\($0)" } ?? "Paperhue"
    }

    public let userAgent: String
    private let session: URLSession
    private let transfers: Transfers

    public convenience init(userAgent: String = URLSessionFeedLoader.defaultUserAgent) {
        self.init(userAgent: userAgent, protocolClasses: nil)
    }

    /// `protocolClasses` replaces the session's URL protocols (tests answer in-process).
    init(userAgent: String, protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Feeds.timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        self.userAgent = userAgent
        transfers = Transfers()
        session = URLSession(configuration: configuration, delegate: transfers, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func load(_ url: String, user: String, password: String) async throws -> Data {
        let host = Feeds.host(of: url)
        guard let request = Self.request(url, user: user, password: password, userAgent: userAgent) else {
            throw FeedError.cannotConnect(host: host, reason: "InvalidURL")  // as Python's http.client says
        }
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfers.start(task, host: host, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The GET for `url`; nil unless it is an http(s) address Foundation can load.
    static func request(_ url: String, user: String, password: String, userAgent: String) -> URLRequest? {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https", target.host?.isEmpty == false else { return nil }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Feeds.timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/calendar, */*", forHTTPHeaderField: "Accept")
        if !user.isEmpty || !password.isEmpty {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Where a redirect from `from` (answered with `status`) to `next` may go: `next` without
    /// Authorization, or the `FeedError` that refuses it (Python's urllib reports a refused
    /// redirect as an HTTP error with the redirect's status). `visited` counts the targets.
    static func redirect(from: URL?, status: Int, to next: URLRequest,
                         visited: inout [String: Int]) -> Result<URLRequest, FeedError> {
        let refused = FeedError.http(status: status)
        guard let target = next.url, let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .failure(refused) }
        if from?.scheme?.lowercased() == "https", scheme == "http" { return .failure(refused) }
        let key = target.absoluteString
        if visited[key, default: 0] >= 4 || visited.count >= 10 { return .failure(refused) }
        visited[key, default: 0] += 1
        var request = next
        request.setValue(nil, forHTTPHeaderField: "Authorization")  // Python: an unredirected header
        return .success(request)
    }

    /// What a transfer error becomes. A cancellation nobody recorded a reason for is the
    /// caller's.
    static func feedError(_ error: any Error, host: String) -> any Error {
        guard let error = error as? URLError else {
            return FeedError.cannotConnect(host: host, reason: String(describing: type(of: error)))
        }
        switch error.code {
        case .cancelled: return CancellationError()
        case .cannotDecodeContentData, .cannotDecodeRawData: return FeedError.damagedCompression
        case .dataLengthExceedsMaximum: return FeedError.tooLarge
        default: return FeedError.cannotConnect(host: host, reason: name(of: error.code))
        }
    }

    /// The `URLError.Code` case name, for "無法連線到 <host>（<name>）".
    static func name(of code: URLError.Code) -> String {
        let names: [URLError.Code: String] = [
            .timedOut: "timedOut", .cannotFindHost: "cannotFindHost", .cannotConnectToHost: "cannotConnectToHost",
            .networkConnectionLost: "networkConnectionLost", .dnsLookupFailed: "dnsLookupFailed",
            .notConnectedToInternet: "notConnectedToInternet", .secureConnectionFailed: "secureConnectionFailed",
            .serverCertificateUntrusted: "serverCertificateUntrusted",
            .serverCertificateHasBadDate: "serverCertificateHasBadDate",
            .serverCertificateHasUnknownRoot: "serverCertificateHasUnknownRoot",
            .serverCertificateNotYetValid: "serverCertificateNotYetValid",
            .clientCertificateRejected: "clientCertificateRejected",
            .clientCertificateRequired: "clientCertificateRequired",
            .appTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection",
            .httpTooManyRedirects: "httpTooManyRedirects",
            .redirectToNonExistentLocation: "redirectToNonExistentLocation",
            .badServerResponse: "badServerResponse", .cannotParseResponse: "cannotParseResponse",
            .zeroByteResource: "zeroByteResource", .badURL: "badURL", .unsupportedURL: "unsupportedURL",
            .userAuthenticationRequired: "userAuthenticationRequired",
            .userCancelledAuthentication: "userCancelledAuthentication", .resourceUnavailable: "resourceUnavailable",
            .internationalRoamingOff: "internationalRoamingOff", .callIsActive: "callIsActive",
            .dataNotAllowed: "dataNotAllowed", .cannotLoadFromNetwork: "cannotLoadFromNetwork",
        ]
        return names[code] ?? "URLError \(code.rawValue)"
    }
}

/// The session's delegate: one entry per running task, the body gathered in memory.
private final class Transfers: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Transfer {
        let host: String
        let continuation: CheckedContinuation<Data, any Error>
        var body = Data()
        /// Why this side stopped the task, if it did.
        var failure: FeedError?
        var visited: [String: Int] = [:]
    }

    private let lock = NSLock()
    private var running: [Int: Transfer] = [:]  // by taskIdentifier; guarded by lock

    func start(_ task: URLSessionDataTask, host: String, continuation: CheckedContinuation<Data, any Error>) {
        lock.withLock { running[task.taskIdentifier] = Transfer(host: host, continuation: continuation) }
        task.resume()
    }

    /// Records why the task is stopped and cancels it.
    private func stop(_ task: URLSessionTask, _ failure: FeedError) {
        lock.withLock { running[task.taskIdentifier]?.failure = failure }
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let host = lock.withLock { running[dataTask.taskIdentifier]?.host } ?? "?"
        guard let http = response as? HTTPURLResponse else {
            stop(dataTask, .cannotConnect(host: host, reason: "badServerResponse"))
            return completionHandler(.cancel)
        }
        if !(200..<300).contains(http.statusCode) {
            stop(dataTask, .http(status: http.statusCode))
            return completionHandler(.cancel)
        }
        let encoded = http.value(forHTTPHeaderField: "Content-Encoding") != nil  // the length is the compressed one
        if http.expectedContentLength > Int64(Feeds.maxBytes), !encoded {
            stop(dataTask, .tooLarge)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            guard var transfer = running[dataTask.taskIdentifier], transfer.failure == nil else { return false }
            if transfer.body.count + data.count > Feeds.maxBytes {
                transfer.body = Data()  // keep nothing of it
                transfer.failure = .tooLarge
                running[dataTask.taskIdentifier] = transfer
                return true
            }
            transfer.body.append(data)
            running[dataTask.taskIdentifier] = transfer
            return false
        }
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let decision = lock.withLock { () -> Result<URLRequest, FeedError> in
            var visited = running[task.taskIdentifier]?.visited ?? [:]
            let decision = URLSessionFeedLoader.redirect(from: response.url ?? task.currentRequest?.url,
                                                         status: response.statusCode, to: request, visited: &visited)
            running[task.taskIdentifier]?.visited = visited
            return decision
        }
        switch decision {
        case .success(let next):
            completionHandler(next)
        case .failure(let failure):
            stop(task, failure)
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = lock.withLock({ running.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = transfer.failure {
            transfer.continuation.resume(throwing: failure)
        } else if let error {
            transfer.continuation.resume(throwing: URLSessionFeedLoader.feedError(error, host: transfer.host))
        } else {
            transfer.continuation.resume(returning: transfer.body)
        }
    }
}
