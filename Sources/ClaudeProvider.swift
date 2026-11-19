import Foundation

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let name = "Claude"
    let usagePageURL = URL(string: "https://claude.ai/settings/usage")!

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch() async throws -> UsageSnapshot {
        let token = try await ClaudeCreds.accessToken()
        var req = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ai-usage-bar/1.0", forHTTPHeaderField: "User-Agent")
        let j = try await getJSON(req)

        func block(_ key: String, _ label: String) -> LimitInfo? {
            guard let b = j[key] as? [String: Any],
                  let u = (b["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitInfo(label: label, percent: u, resetsAt: ISO.date(b["resets_at"]))
        }

        var others: [LimitInfo] = []
        if let w = block("seven_day", "Weekly (all models)") { others.append(w) }
        if let limits = j["limits"] as? [[String: Any]] {
            for l in limits where (l["kind"] as? String) == "weekly_scoped" {
                let scope = l["scope"] as? [String: Any]
                let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String) ?? "Scoped"
                if let p = (l["percent"] as? NSNumber)?.doubleValue {
                    others.append(LimitInfo(label: "Weekly · \(model)", percent: p, resetsAt: ISO.date(l["resets_at"])))
                }
            }
        }
        for (k, n) in [("seven_day_opus", "Weekly · Opus"), ("seven_day_sonnet", "Weekly · Sonnet")] {
            if let b = block(k, n), !others.contains(where: { $0.label == n }) { others.append(b) }
        }
        return UsageSnapshot(primary: block("five_hour", "Session (5h)"), others: others, fetchedAt: Date())
    }
}

enum ClaudeCreds {
    static let service = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    @discardableResult
    static func security(_ args: [String], stdin: String? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        let inp = Pipe()
        if stdin != nil { p.standardInput = inp }
        do { try p.run() } catch { return (-1, "") }
        if let s = stdin {
            inp.fileHandleForWriting.write(Data(s.utf8))
            inp.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func readBlob() -> [String: Any]? {
        let (code, out) = security(["find-generic-password", "-s", service, "-w"])
        if code == 0,
           let j = try? JSONSerialization.jsonObject(with: Data(out.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any] {
            return j
        }
        if let d = try? Data(contentsOf: fileURL),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
        return nil
    }

    static func keychainAccount() -> String {
        let (_, out) = security(["find-generic-password", "-s", service])
        for line in out.split(separator: "\n") where line.contains("\"acct\"") {
            if let r = line.range(of: "=\"") { return String(line[r.upperBound...].dropLast()) }
        }
        return NSUserName()
    }

    static func writeBlob(_ blob: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: blob) else { return }
        let hex = d.map { String(format: "%02x", $0) }.joined()
        security(["-i"], stdin: "add-generic-password -U -a \"\(keychainAccount())\" -s \"\(service)\" -X \(hex)\n")

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let fd = try? Data(contentsOf: fileURL),
              var fj = try? JSONSerialization.jsonObject(with: fd) as? [String: Any],
              let oauth = blob["claudeAiOauth"] as? [String: Any] else { return }
        var fo = (fj["claudeAiOauth"] as? [String: Any]) ?? [:]
        for k in ["accessToken", "refreshToken", "expiresAt"] { fo[k] = oauth[k] }
        fj["claudeAiOauth"] = fo
        if let out = try? JSONSerialization.data(withJSONObject: fj) {
            try? out.write(to: fileURL, options: .atomic)
            chmod(fileURL.path, 0o600)
        }
    }

    static func accessToken() async throws -> String {
        let hint = "sign in to the Claude desktop app or Claude Code"
        guard var blob = readBlob(), var oauth = blob["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { throw FetchError.notSignedIn(hint) }
        let expMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        if expMs / 1000 > Date().timeIntervalSince1970 + 60 { return token }

        guard let refresh = oauth["refreshToken"] as? String else { throw FetchError.notSignedIn(hint) }
        let scopes = (oauth["scopes"] as? [String]) ?? ["user:profile", "user:inference"]
        var req = URLRequest(url: tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": clientID, "scope": scopes.joined(separator: " "),
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = j["access_token"] as? String else {
            throw FetchError.refreshFailed("HTTP \(code)")
        }
        oauth["accessToken"] = newAccess
        if let r = j["refresh_token"] as? String { oauth["refreshToken"] = r }
        if let e = (j["expires_in"] as? NSNumber)?.doubleValue {
            oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + e) * 1000)
        }
        blob["claudeAiOauth"] = oauth
        writeBlob(blob)
        return newAccess
    }
}
