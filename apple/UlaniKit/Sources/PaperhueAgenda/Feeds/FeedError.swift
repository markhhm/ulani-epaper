import Foundation

/// Why a calendar source could not be added or read. No case holds the address: a source's
/// address is a password, so messages name only the feed and the host.
///
/// `description` is the Python reference's text (Traditional Chinese for the sources, English
/// for the settings checks); `message(inChinese:)` gives every case in either language.
public indirect enum FeedError: Error, Equatable, Sendable {
    /// The pasted address has whitespace or a control character inside.
    case spacesInAddress
    /// Not an http(s) or webcal(s) address with a host.
    case notAnAddress
    /// The address carries a user name or password (they go in their own fields).
    case loginInAddress
    /// The server answered with this HTTP status (a refused redirect counts as its status).
    case http(status: Int)
    /// No answer from `host`; `reason` names the kind of failure (`URLError` code name).
    case cannotConnect(host: String, reason: String)
    /// The body was compressed and could not be decompressed.
    case damagedCompression
    /// The body is larger than `Feeds.maxBytes`.
    case tooLarge
    /// The body is not iCalendar data (the parse step failed).
    case notICalendar
    /// No address is stored for this feed.
    case missingAddress
    /// No calendar source is set up at all (Python: `NoFeeds`, not retried).
    case noFeeds
    /// One feed failed; the whole fetch fails with its name in front (Python: "個人：…").
    case inFeed(name: String, FeedError)
    /// The Keychain refused (an `OSStatus`; -34018 = the app is not entitled to it).
    case keychain(status: Int32)
    /// Settings: feed ids must be unique and 1-40 of 0-9 A-Z a-z _ -; all ids are listed.
    case invalidFeedIDs([String])
    /// Settings: a feed's name is empty or only whitespace.
    case unnamedFeed
    /// Settings: a feed's colour is neither a panel colour name, "#rrggbb" nor "".
    case invalidFeedColour(feed: String)

    public func message(inChinese: Bool) -> String {
        switch self {
        case .spacesInAddress:
            inChinese ? "網址中間有空白或換行，請重新複製整段網址"
                : "The address has spaces or line breaks in it; copy the whole address again"
        case .notAnAddress:
            inChinese ? "這不是有效的行事曆網址（要以 https:// 或 webcal:// 開頭）"
                : "This is not a valid calendar address (it must start with https:// or webcal://)"
        case .loginInAddress:
            inChinese ? "網址裡不要放帳號密碼，請分開填在「帳號」「密碼」"
                : "Do not put a user name or password in the address; enter them under User name and Password"
        case .http(let status):
            "HTTP \(status)" + (inChinese ? "（\(Self.hint(status, inChinese: true))）"
                : " (\(Self.hint(status, inChinese: false)))")
        case .cannotConnect(let host, let reason):
            inChinese ? "無法連線到 \(host)（\(reason)）" : "Cannot connect to \(host) (\(reason))"
        case .damagedCompression:
            inChinese ? "收到損壞的壓縮資料" : "The compressed data received is damaged"
        case .tooLarge:
            inChinese ? "行事曆大於 \(Feeds.maxBytes / (1024 * 1024)) MB，不處理"
                : "The calendar is larger than \(Feeds.maxBytes / (1024 * 1024)) MB and is not read"
        case .notICalendar:
            inChinese ? "收到的不是 iCalendar 資料（網址可能不對，或需要登入）"
                : "What came back is not iCalendar data (the address may be wrong, or a login may be needed)"
        case .missingAddress:
            inChinese ? "找不到這個來源的網址，請重新加入" : "This source's address is missing; add the source again"
        case .noFeeds:
            inChinese ? "尚未設定行事曆來源" : "No calendar source is set up yet"
        case .inFeed(let name, let error):
            name + (inChinese ? "：" : ": ") + error.message(inChinese: inChinese)
        case .keychain(let status):
            inChinese ? "無法存取鑰匙圈中的行事曆網址（OSStatus \(status)）"
                : "Cannot use the calendar address in the Keychain (OSStatus \(status))"
        case .invalidFeedIDs(let ids):
            inChinese ? "行事曆來源的代碼必須不重複且只用英數字、_ 和 -，收到 \(pythonList(ids))"
                : "feed ids must be unique and simple, got \(pythonList(ids))"
        case .unnamedFeed:
            inChinese ? "每個行事曆來源都需要名稱" : "every feed needs a name"
        case .invalidFeedColour(let feed):
            inChinese ? "行事曆來源 \(feed) 的顏色必須是 \(Feed.colours.joined(separator: ", ")) 或 #rrggbb"
                : "feed \(feed): colour must be one of \(Feed.colours.joined(separator: ", ")) or #rrggbb"
        }
    }

    /// The error without the feed name in front.
    public var withoutFeedName: FeedError {
        if case .inFeed(_, let error) = self { error.withoutFeedName } else { self }
    }

    /// Python: the hints of `feeds.download` by status.
    private static func hint(_ status: Int, inChinese: Bool) -> String {
        switch status {
        case 400: inChinese ? "網址無效，或已被重設" : "the address is invalid, or has been reset"
        case 401: inChinese ? "需要帳號密碼，或密碼不對" : "a user name and password are needed, or the password is wrong"
        case 403: inChinese ? "沒有權限" : "no permission"
        case 404: inChinese ? "找不到：網址可能已重設或刪除" : "not found: the address may have been reset or deleted"
        case 410: inChinese ? "已刪除" : "deleted"
        default: inChinese ? "伺服器拒絕" : "refused by the server"
        }
    }

    /// Whether the Python reference words this case in Chinese (the settings checks are its
    /// English ValueErrors).
    var pythonSaysItInChinese: Bool {
        switch self {
        case .invalidFeedIDs, .unnamedFeed, .invalidFeedColour: false
        case .inFeed(_, let error): error.pythonSaysItInChinese
        default: true
        }
    }
}

extension FeedError: CustomStringConvertible, LocalizedError {
    /// The Python reference's text.
    public var description: String { message(inChinese: pythonSaysItInChinese) }

    /// The app's language: Traditional Chinese.
    public var errorDescription: String? { message(inChinese: true) }
}

/// Python's `repr()` of a list of strings: "['a', 'b']".
private func pythonList(_ items: [String]) -> String {
    "[" + items.map(pythonRepr).joined(separator: ", ") + "]"
}
