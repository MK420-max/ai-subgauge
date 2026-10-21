import Foundation
import CoreFoundation

/// Reads billing metadata only. No inference request is made to measure quota.
enum APIUsageSource {
    static func supportsDirectFetch(_ provider: AIUsageProvider) -> Bool {
        [.deepseekAPI, .openrouterAPI, .kimiAPI, .minimaxAPI, .xaiAPI].contains(provider)
    }

    static func dashboardURL(_ provider: AIUsageProvider) -> URL {
        let address: String
        switch provider {
        case .codex: address = "https://chatgpt.com/codex/settings/usage"
        case .claude: address = "https://claude.ai/settings/usage"
        case .grok: address = "https://grok.com/"
        case .openaiAPI: address = "https://platform.openai.com/usage"
        case .anthropicAPI: address = "https://platform.claude.com/usage"
        case .geminiAPI: address = "https://aistudio.google.com/usage"
        case .xaiAPI: address = "https://console.x.ai/"
        case .deepseekAPI: address = "https://platform.deepseek.com/usage"
        case .openrouterAPI: address = "https://openrouter.ai/settings/credits"
        case .kimiAPI: address = "https://platform.kimi.com/console/account"
        case .minimaxAPI: address = "https://platform.minimax.io/"
        }
        return URL(string: address)!
    }

    static func documentationURL(_ provider: AIUsageProvider) -> URL {
        let address: String
        switch provider {
        case .openaiAPI: address = "https://developers.openai.com/api/docs/guides/admin-apis"
        case .anthropicAPI: address = "https://platform.claude.com/docs/en/manage-claude/usage-cost-api"
        case .geminiAPI: address = "https://ai.google.dev/gemini-api/docs/billing"
        case .xaiAPI: address = "https://docs.x.ai/developers/rest-api-reference/management/billing"
        case .deepseekAPI: address = "https://api-docs.deepseek.com/api/get-user-balance/"
        case .openrouterAPI: address = "https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key"
        case .kimiAPI: address = "https://platform.kimi.com/docs/api/balance"
        case .minimaxAPI: address = "https://github.com/MiniMax-AI/cli/blob/main/src/types/api.ts"
        default: return dashboardURL(provider)
        }
        return URL(string: address)!
    }

    static func availabilityNote(_ provider: AIUsageProvider) -> String {
        switch provider {
        case .deepseekAPI: return L10n.text("account.reads.the.account.balance.using.a.deepseek")
        case .openrouterAPI: return L10n.text("account.reads.the.remaining.limit.of.the.current")
        case .kimiAPI: return L10n.text("account.supports.kimi.china.api.keys.with.balances")
        case .minimaxAPI: return L10n.text("account.supports.minimax.international.sk.api.keys.read")
        case .openaiAPI: return L10n.text("account.the.official.organization.usage.and.cost.apis")
        case .anthropicAPI: return L10n.text("account.the.official.usage.and.cost.apis.require")
        case .geminiAPI: return L10n.text("account.see.google.ai.studio.for.gemini.api")
        case .xaiAPI: return L10n.text("account.reads.the.team.s.prepaid.balance.in")
        default: return L10n.text("account.subscription.quota.and.api.billing.are.separate")
        }
    }

    private static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw AIUsageError.unavailable(L10n.text("account.invalid.key.format.enter.it.again.without"))
        }
    }

    private static func validateTeamID(_ teamID: String) throws {
        guard (1...128).contains(teamID.utf8.count), teamID.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }) else { throw AIUsageError.unavailable(L10n.text("account.invalid.team.id.use.1.to.128")) }
    }

    /// Store this compact payload as one Keychain item; it contains the secret key.
    static func xaiCredential(key: String, teamID: String) throws -> String {
        try validateKey(key)
        try validateTeamID(teamID)
        let data = try JSONSerialization.data(withJSONObject: ["key": key, "teamID": teamID], options: [.sortedKeys, .withoutEscapingSlashes])
        let encoded = String(decoding: data, as: UTF8.self)
        try validateKey(encoded)
        return encoded
    }

    static func makeRequest(provider: AIUsageProvider, credential: String) throws -> URLRequest {
        guard supportsDirectFetch(provider) else { throw AIUsageError.unavailable(availabilityNote(provider)) }
        let key: String
        let teamID: String?
        if provider == .xaiAPI {
            try validateKey(credential)
            guard let data = credential.data(using: .utf8),
                  let material = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let managementKey = material["key"] as? String, let team = material["teamID"] as? String else {
                throw AIUsageError.unavailable(L10n.text("account.enter.an.xai.management.key.and.the"))
            }
            try validateKey(managementKey)
            try validateTeamID(team)
            key = managementKey
            teamID = team
        } else {
            try validateKey(credential)
            key = credential
            teamID = nil
        }
        let address: String
        switch provider {
        case .deepseekAPI: address = "https://api.deepseek.com/user/balance"
        case .openrouterAPI: address = "https://openrouter.ai/api/v1/key"
        case .kimiAPI: address = "https://api.moonshot.cn/v1/users/me/balance"
        case .xaiAPI:
            guard let teamID else { throw AIUsageError.invalidResponse }
            address = "https://management-api.x.ai/v1/billing/teams/" + teamID + "/prepaid/balance"
        case .minimaxAPI:
            address = credential.hasPrefix("sk-api-")
                ? "https://api.minimax.io/account/query_balance"
                : "https://www.minimax.io/v1/token_plan/remains"
        default: throw AIUsageError.invalidResponse
        }
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func fetch(provider: AIUsageProvider, credential: String) async throws -> AIUsageSnapshot {
        let request = try makeRequest(provider: provider, credential: credential)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoUsageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url == request.url else { throw AIUsageError.invalidResponse }
            guard response.statusCode == 200 else {
                if [401, 403].contains(response.statusCode) {
                    throw AIUsageError.unavailable(L10n.text("account.the.key.is.invalid.expired.or.lacks"))
                }
                throw AIUsageError.unavailable(L10n.text("account.the.official.quota.service.is.temporarily.unavailable", response.statusCode))
            }
            guard response.expectedContentLength <= 1_000_000 else { throw AIUsageError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_000_000 else { throw AIUsageError.invalidResponse }
                data.append(byte)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIUsageError.invalidResponse }
            return try parse(provider: provider, response: object)
        } catch is CancellationError { throw CancellationError() }
        catch let error as AIUsageError { throw error }
        catch let error as URLError where error.code == .timedOut { throw AIUsageError.timeout }
        catch { throw AIUsageError.unavailable(L10n.text("account.could.not.connect.to.the.official.quota")) }
    }

    static func parse(provider: AIUsageProvider, response: [String: Any], now: Date = Date()) throws -> AIUsageSnapshot {
        guard supportsDirectFetch(provider), response["error"] == nil else { throw AIUsageError.invalidResponse }
        var snapshot = AIUsageSnapshot(provider: provider, isConnected: true, status: L10n.text("status.updated"), source: L10n.text("account.official.api.quota.endpoint"), updatedAt: now)
        switch provider {
        case .deepseekAPI:
            guard response["is_available"] is Bool,
                  let balances = response["balance_infos"] as? [[String: Any]], !balances.isEmpty else { throw AIUsageError.invalidResponse }
            snapshot.balance = try balances.map { balance in
                guard let currency = balance["currency"] as? String, ["CNY", "USD"].contains(currency),
                      let amount = decimal(balance["total_balance"]), amount >= 0 else { throw AIUsageError.invalidResponse }
                return money(amount, currency: currency)
            }.joined(separator: " · ")
        case .openrouterAPI:
            guard let info = response["data"] as? [String: Any], let usage = decimal(info["usage"]), usage >= 0 else { throw AIUsageError.invalidResponse }
            snapshot.plan = L10n.text("account.current.api.key")
            if let rawLimit = info["limit"], !(rawLimit is NSNull) {
                guard let limit = decimal(rawLimit), limit >= 0 else { throw AIUsageError.invalidResponse }
                let remaining: Double
                if let reported = info["limit_remaining"], !(reported is NSNull) {
                    guard let value = decimal(reported), value >= 0, value <= limit else { throw AIUsageError.invalidResponse }
                    remaining = value
                } else {
                    // Periodic usage cannot be subtracted from the lifetime usage field.
                    guard info["limit_reset"] == nil || info["limit_reset"] is NSNull else {
                        snapshot.status = L10n.text("account.the.service.did.not.return.remaining.quota")
                        return snapshot
                    }
                    remaining = max(0, limit - usage)
                }
                snapshot.balance = money(remaining, currency: "USD") + L10n.text("account.key.limit")
                if limit > 0 {
                    snapshot.windows = [AIUsageWindow(id: "key.limit", title: L10n.text("account.key.remaining.limit"), remainingPercent: remaining / limit * 100, resetsAt: nil)]
                }
            } else {
                snapshot.status = L10n.text("account.this.key.has.no.limit.see.official")
            }
        case .kimiAPI:
            guard decimal(response["code"]) == 0, response["status"] as? Bool == true,
                  let info = response["data"] as? [String: Any], let amount = decimal(info["available_balance"]) else { throw AIUsageError.invalidResponse }
            // The official balance schema permits a negative amount after delayed billing.
            snapshot.balance = money(amount, currency: "CNY")
            snapshot.plan = L10n.text("account.china.api")
        case .xaiAPI:
            guard let total = response["total"] as? [String: Any],
                  let rawCents = total["val"] as? String, let cents = Int64(rawCents) else { throw AIUsageError.invalidResponse }
            // The official PURCHASE example credits -1000 USD cents and returns total.val=-1000.
            // This is a signed ledger balance: negate it for available credit, retaining debt as negative.
            snapshot.balance = money(cents == 0 ? 0 : -Double(cents) / 100, currency: "USD")
            snapshot.plan = L10n.text("account.team.prepaid.api.balance")
        case .minimaxAPI:
            if let base = response["base_resp"] as? [String: Any] {
                guard decimal(base["status_code"]) == 0 else { throw AIUsageError.invalidResponse }
            }
            snapshot.plan = L10n.text("account.international.api.token.plan")
            if let rawAmount = response["available_amount"] {
                guard let amount = decimal(rawAmount), amount >= 0,
                      let base = response["base_resp"] as? [String: Any], decimal(base["status_code"]) == 0 else { throw AIUsageError.invalidResponse }
                // The published schema does not specify currency; do not invent one.
                snapshot.balance = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount) + L10n.text("account.available.account.balance")
            } else {
                guard let models = response["model_remains"] as? [[String: Any]], !models.isEmpty else { throw AIUsageError.invalidResponse }
                for (index, model) in models.enumerated() {
                    for (prefix, title, end) in [("current_interval", L10n.text("account.current.period"), "end_time"), ("current_weekly", L10n.text("quota.weekly"), "weekly_end_time")] {
                        // Historical *_usage_count fields have ambiguous semantics. Only trust explicit remaining percentages.
                        let raw = model[prefix + "_remaining_percent"]
                        guard let raw, !(raw is NSNull) else { continue }
                        guard let percent = decimal(raw), (0...100).contains(percent) else { throw AIUsageError.invalidResponse }
                        let modelName = String((model["model_name"] as? String ?? L10n.text("account.model")).prefix(64))
                        let reset = decimal(model[end]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
                        snapshot.windows.append(AIUsageWindow(id: "model.\(index).\(prefix)", title: modelName + " · " + title, remainingPercent: percent, resetsAt: reset))
                    }
                }
                if snapshot.windows.isEmpty { snapshot.status = L10n.text("account.connected.the.service.has.not.returned.a") }
            }
        default: throw AIUsageError.invalidResponse
        }
        return snapshot
    }

    private static func decimal(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { return number.doubleValue }
        if let string = value as? String, let number = Double(string), number.isFinite { return number }
        return nil
    }

    private static func money(_ amount: Double, currency: String) -> String {
        currency + " " + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }
}

