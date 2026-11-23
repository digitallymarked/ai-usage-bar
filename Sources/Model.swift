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

/// Something the user can click in the setup wizard.
struct SetupAction {
    enum Kind {
        case openURL(URL)
        case runInTerminal(String)   // opens Terminal running this command
        case copy(String)            // copies text; shown as a command box
    }
    let title: String
    let kind: Kind
}

/// What to tell the user when a provider isn't connected yet.
struct SetupGuide {
    let headline: String
    let steps: [String]
    let actions: [SetupAction]
}

enum SetupStatus {
    case signedIn
    case needsSetup(SetupGuide)
}

protocol UsageProvider {
    var id: String { get }
    var name: String { get }
    var usagePageURL: URL { get }
    func fetch() async throws -> UsageSnapshot

    // Setup wizard metadata. A new provider only has to implement these.
    var planRequired: String { get }
    /// Shown before the first fetch when it triggers a system prompt; nil = fetch immediately.
    var connectNotice: String? { get }
    /// Detects credentials without any network call or secret read.
    func setupStatus() -> SetupStatus
    /// Offered on the failure screen to sign in again.
    var reconnectAction: SetupAction? { get }
}

extension UsageProvider {
    var connectNotice: String? { nil }
    var reconnectAction: SetupAction? { nil }
}

enum Shell {
    /// Finds a CLI. GUI apps get a minimal PATH, so common install dirs are searched too.
    static func find(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.bun/bin", "\(home)/.claude/local"]
        for dir in path + extra {
            let f = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: f) { return f }
        }
        return nil
    }
}

/// Persistent settings. `AI_USAGE_BAR_DEFAULTS_SUITE` points them at an isolated domain for testing.
enum Settings {
    static let defaults: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["AI_USAGE_BAR_DEFAULTS_SUITE"],
           let d = UserDefaults(suiteName: suite) { return d }
        return .standard
    }()
    static let setupKey = "setupComplete"

    /// Users who picked a provider before the wizard existed count as set up.
    static var setupComplete: Bool {
        get {
            if defaults.bool(forKey: setupKey) { return true }
            if defaults.string(forKey: Providers.defaultsKey) != nil { defaults.set(true, forKey: setupKey); return true }
            return false
        }
        set { defaults.set(newValue, forKey: setupKey) }
    }
}

enum Providers {
    static let all: [UsageProvider] = [ClaudeProvider(), CodexProvider()]
    static let defaultsKey = "provider"

    static var selected: UsageProvider {
        get {
            let id = Settings.defaults.string(forKey: defaultsKey) ?? all[0].id
            return all.first { $0.id == id } ?? all[0]
        }
        set { Settings.defaults.set(newValue.id, forKey: defaultsKey) }
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
