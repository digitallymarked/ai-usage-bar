import Foundation

struct CodexProvider: UsageProvider {
    let id = "codex"
    let name = "OpenAI Codex"
    let usagePageURL = URL(string: "https://chatgpt.com/settings/usage")!

    static let usageURL = URL(string: ProcessInfo.processInfo.environment["AI_USAGE_BAR_CODEX_URL"]
        ?? "https://chatgpt.com/backend-api/wham/usage")!

    static var authURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    let planRequired = "ChatGPT Plus, Pro or Team"

    var reconnectAction: SetupAction? { SetupAction(title: "Run codex login", kind: .runInTerminal("codex login")) }

    static func hasLogin() -> Bool {
        guard let d = try? Data(contentsOf: authURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = j["tokens"] as? [String: Any], t["access_token"] is String else { return false }
        return true
    }

    func setupStatus() -> SetupStatus {
        if Self.hasLogin() { return .signedIn }
        if Shell.find("codex") != nil {
            return .needsSetup(SetupGuide(
                headline: "Codex is installed but not signed in",
                steps: ["Press the button to open Terminal and run `codex login`.",
                        "Finish signing in with your ChatGPT account in the browser.",
                        "Come back here and press Check again."],
                actions: [SetupAction(title: "Open Terminal and sign in", kind: .runInTerminal("codex login"))]))
        }
        return .needsSetup(SetupGuide(
            headline: "The Codex CLI isn't installed",
            steps: ["Install it by pasting this into Terminal:",
                    "Run `codex login` and sign in with your ChatGPT account.",
                    "Come back here and press Check again."],
            actions: [SetupAction(title: "npm install -g @openai/codex", kind: .copy("npm install -g @openai/codex")),
                      SetupAction(title: "Codex install docs", kind: .openURL(URL(string: "https://github.com/openai/codex")!))]))
    }

    func fetch() async throws -> UsageSnapshot {
        let hint = "run `codex login` with your ChatGPT account"
        guard let d = try? Data(contentsOf: Self.authURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tokens = j["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { throw FetchError.notSignedIn(hint) }

        var req = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            req.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        }
        req.setValue("ai-usage-bar/1.0", forHTTPHeaderField: "User-Agent")
        let r = try await getJSON(req)

        guard let rl = r["rate_limit"] as? [String: Any] else {
            return UsageSnapshot(primary: nil, others: [], fetchedAt: Date())
        }
        func window(_ key: String) -> LimitInfo? {
            guard let w = rl[key] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let secs = (w["limit_window_seconds"] as? NSNumber)?.doubleValue
            let reset = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitInfo(label: Self.label(forWindow: secs), percent: used, resetsAt: reset)
        }
        return UsageSnapshot(primary: window("primary_window"),
                             others: [window("secondary_window")].compactMap { $0 },
                             fetchedAt: Date())
    }

    static func label(forWindow secs: Double?) -> String {
        guard let s = secs, s > 0 else { return "Usage" }
        let h = s / 3600
        if h >= 24 * 6.5 { return "Weekly" }
        if h >= 24 { return "\(Int((h / 24).rounded()))-day" }
        if h >= 1 { return "Session (\(Int(h.rounded()))h)" }
        return "\(Int((s / 60).rounded()))-minute"
    }
}
