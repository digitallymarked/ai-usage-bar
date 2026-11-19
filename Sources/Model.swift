import Foundation

struct LimitInfo {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct UsageSnapshot {
    let primary: LimitInfo?
    let others: [LimitInfo]
    let fetchedAt: Date
}

enum FetchError: Error, CustomStringConvertible {
    case notSignedIn(String)
    case refreshFailed(String)
    case http(Int)
    case parse
    case network(String)

    var description: String {
        switch self {
        case .notSignedIn(let hint): return "Not signed in — \(hint)"
        case .refreshFailed(let s): return "Token refresh failed: \(s)"
        case .http(401), .http(403): return "Session expired — reopen the provider's app to sign in again"
        case .http(let c): return "HTTP \(c)"
        case .parse: return "Unexpected response"
        case .network(let s): return s
        }
    }
}

protocol UsageProvider {
    var id: String { get }
    var name: String { get }
    var usagePageURL: URL { get }
    func fetch() async throws -> UsageSnapshot
}

enum Providers {
    static let all: [UsageProvider] = [ClaudeProvider(), CodexProvider()]
    static let defaultsKey = "provider"

    static var selected: UsageProvider {
        get {
            let id = UserDefaults.standard.string(forKey: defaultsKey) ?? all[0].id
            return all.first { $0.id == id } ?? all[0]
        }
        set { UserDefaults.standard.set(newValue.id, forKey: defaultsKey) }
    }
}

enum ISO {
    static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return frac.date(from: s) ?? plain.date(from: s)
    }
}

func getJSON(_ req: URLRequest) async throws -> [String: Any] {
    let data: Data, resp: URLResponse
    do { (data, resp) = try await URLSession.shared.data(for: req) }
    catch { throw FetchError.network(error.localizedDescription) }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw FetchError.http(code) }
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.parse }
    return j
}
