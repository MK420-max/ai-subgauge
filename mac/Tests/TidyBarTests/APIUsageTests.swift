import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class APIUsageTests {
    @Test
    func testDeepSeekOfficialBalanceKeepsCurrenciesAndHasNoInventedPercentage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try APIUsageSource.parse(provider: .deepseekAPI, response: [
            "is_available": true, "balance_infos": [
                ["currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"],
                ["currency": "USD", "total_balance": "2.50"]
            ]
        ], now: now)
        #expect(snapshot.balance == "CNY 110.00 · USD 2.50")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.isConnected)
    }

    @Test
    func testBalanceRejectsMissingInvalidNonFiniteBooleanAndNegativeValues() {
        for value: Any in ["invalid", "nan", "inf", -1, true, NSNull()] {
            #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .deepseekAPI, response: [
                "is_available": true, "balance_infos": [["currency": "CNY", "total_balance": value]]
            ]) }
        }
        #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .deepseekAPI, response: ["is_available": true]) }
        #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .deepseekAPI, response: [
            "is_available": true, "balance_infos": [["currency": "unknown", "total_balance": "1"]]
        ]) }
    }

    @Test
    func testOpenRouterUsesOfficialKeyLimitRemainingRatherThanLifetimeUsage() throws {
        let snapshot = try APIUsageSource.parse(provider: .openrouterAPI, response: ["data": [
            "limit": 100, "limit_remaining": 74.5, "usage": 500, "limit_reset": "monthly"
        ]])
        #expect(snapshot.balance == "USD 74.50（Key 限额）")
        #expect(snapshot.windows.first?.remainingPercent == 74.5)
        #expect(snapshot.windows.first?.resetsAt == nil, "重置周期名称不能推测确切重置时间")
    }

    @Test
    func testOpenRouterUnlimitedAndZeroLimitsCannotBecomeFullPercentage() throws {
        for limit: Any in [NSNull(), 0] {
            let snapshot = try APIUsageSource.parse(provider: .openrouterAPI, response: ["data": ["limit": limit, "usage": 0]])
            #expect(snapshot.windows.isEmpty)
        }
        let missing = try APIUsageSource.parse(provider: .openrouterAPI, response: ["data": ["usage": 25.5]])
        #expect(missing.balance == nil)
        #expect(missing.windows.isEmpty)
    }

    @Test
    func testOpenRouterDoesNotInferMonthlyRemainingFromLifetimeCost() throws {
        let snapshot = try APIUsageSource.parse(provider: .openrouterAPI, response: ["data": [
            "limit": 100, "usage": 500, "limit_reset": "monthly"
        ]])
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.balance == nil)
        let lifetime = try APIUsageSource.parse(provider: .openrouterAPI, response: ["data": ["limit": 100, "usage": 25]])
        #expect(lifetime.windows.first?.remainingPercent == 75)
    }

    @Test
    func testOpenRouterRejectsMalformedAndNegativeLimits() {
        for info: [String: Any] in [
            ["limit": -1, "usage": 0], ["limit": 100, "usage": -1],
            ["limit": 100, "usage": 0, "limit_remaining": -1],
            ["limit": 100, "usage": 0, "limit_remaining": 101],
            ["limit": true, "usage": 0], ["limit": 100]
        ] {
            #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .openrouterAPI, response: ["data": info]) }
        }
    }

    @Test
    func testKimiOfficialChinaBalanceAndDelayedBillingDebt() throws {
        let snapshot = try APIUsageSource.parse(provider: .kimiAPI, response: [
            "code": 0, "status": true, "data": ["available_balance": 49.58894, "voucher_balance": 46.58893, "cash_balance": 3.00001]
        ])
        #expect(snapshot.balance == "CNY 49.59")
        #expect(snapshot.windows.isEmpty)
        let debt = try APIUsageSource.parse(provider: .kimiAPI, response: ["code": 0, "status": true, "data": ["available_balance": -1]])
        #expect(debt.balance == "CNY -1.00", "官方允许余额为负，须如实保留")
        #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .kimiAPI, response: ["code": 123, "status": true, "data": ["available_balance": 1]]) }
        #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .kimiAPI, response: ["code": 0, "status": false, "data": ["available_balance": 1]]) }
    }

    @Test
    func testMiniMaxOfficialExplicitPercentagesAndMillisecondDates() throws {
        let snapshot = try APIUsageSource.parse(provider: .minimaxAPI, response: [
            "base_resp": ["status_code": 0], "model_remains": [[
                "model_name": "MiniMax-M*", "current_interval_remaining_percent": 85,
                "current_weekly_remaining_percent": 97, "end_time": 1_800_000_000_000,
                "weekly_end_time": 1_800_100_000_000
            ]]
        ])
        #expect(snapshot.windows.map(\.remainingPercent) == [85, 97])
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_800_100_000))
    }

    @Test
    func testMiniMaxAmbiguousCountFieldsNeverBecomeGuessedPercentage() throws {
        let snapshot = try APIUsageSource.parse(provider: .minimaxAPI, response: ["model_remains": [[
            "model_name": "MiniMax-M*", "current_interval_total_count": 1500, "current_interval_usage_count": 228
        ]]])
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.isConnected)
        for percent: Any in [-1, 101, true, "nan"] {
            #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .minimaxAPI, response: ["model_remains": [["current_interval_remaining_percent": percent]]]) }
        }
    }

    @Test
    func testMiniMaxBalanceDoesNotInventCurrencyOrPercentage() throws {
        let snapshot = try APIUsageSource.parse(provider: .minimaxAPI, response: [
            "available_amount": "12.34", "base_resp": ["status_code": 0]
        ])
        #expect(snapshot.balance == "12.34（账户可用金额）")
        #expect(snapshot.windows.isEmpty)
        #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .minimaxAPI, response: ["available_amount": "12.34"]) }
        #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .minimaxAPI, response: ["available_amount": "12.34", "base_resp": ["status_code": 1004]]) }
    }

    @Test
    func testFixedOfficialHTTPSDestinationsAndNoKeyInURL() throws {
        let expected: [(AIUsageProvider, String)] = [
            (.deepseekAPI, "https://api.deepseek.com/user/balance"),
            (.openrouterAPI, "https://openrouter.ai/api/v1/key"),
            (.kimiAPI, "https://api.moonshot.cn/v1/users/me/balance"),
            (.minimaxAPI, "https://www.minimax.io/v1/token_plan/remains")
        ]
        for (provider, address) in expected {
            let request = try APIUsageSource.makeRequest(provider: provider, credential: "fixture-token")
            #expect(request.url?.absoluteString == address)
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 20)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(!(request.url!.absoluteString.contains("fixture-token")))
            #expect(request.httpBody == nil)
        }
        let request = try APIUsageSource.makeRequest(provider: .minimaxAPI, credential: "sk-api-fixture-only")
        #expect(request.url?.absoluteString == "https://api.minimax.io/account/query_balance")
    }

    @Test
    func testUnsupportedProvidersHaveBillLinksWithoutRequestingAdminCredentials() async {
        for provider: AIUsageProvider in [.openaiAPI, .anthropicAPI, .geminiAPI] {
            #expect(!(APIUsageSource.supportsDirectFetch(provider)))
            #expect(APIUsageSource.dashboardURL(provider).scheme == "https")
            #expect(APIUsageSource.documentationURL(provider).scheme == "https")
            do { _ = try await APIUsageSource.fetch(provider: provider, credential: "fixture-token"); Issue.record("不得发出模型或管理员接口请求") }
            catch { #expect(!(error.localizedDescription.contains("fixture-token"))) }
        }
    }

    @Test
    func testXAIManagementCredentialUsesCompactJSONAndOnlyOfficialBalanceGET() throws {
        let credential = try APIUsageSource.xaiCredential(key: "fixture-management-key", teamID: "team_Fixture-123")
        #expect(!(credential.contains(" ")))
        #expect(!(credential.contains("\n")))
        #expect(credential == "{\"key\":\"fixture-management-key\",\"teamID\":\"team_Fixture-123\"}")
        let request = try APIUsageSource.makeRequest(provider: .xaiAPI, credential: credential)
        #expect(APIUsageSource.supportsDirectFetch(.xaiAPI))
        #expect(request.url?.absoluteString == "https://management-api.x.ai/v1/billing/teams/team_Fixture-123/prepaid/balance")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-management-key")
        #expect(request.url?.query == nil)
        #expect(request.httpBody == nil)
        #expect(request.httpMethod == "GET")
        #expect(!(request.url!.absoluteString.contains("fixture-management-key")))
        let escaped = try APIUsageSource.xaiCredential(key: "fixture/quoted\"key", teamID: "fixture")
        #expect(try APIUsageSource.makeRequest(provider: .xaiAPI, credential: escaped).value(forHTTPHeaderField: "Authorization") == "Bearer fixture/quoted\"key")
    }

    @Test
    func testXAITeamIDCannotInjectPathHostQueryOrHeader() throws {
        for teamID in ["", "../team", "team/path", "team?key=secret", "team#fragment", "https://example.com", "team%2Fpath", "team\nHeader", "团队", String(repeating: "a", count: 129)] {
            #expect(throws: (any Error).self) { try APIUsageSource.xaiCredential(key: "fixture-key", teamID: teamID) }
            let tampered = try JSONSerialization.data(withJSONObject: ["key": "fixture-key", "teamID": teamID], options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(throws: (any Error).self) { try APIUsageSource.makeRequest(provider: .xaiAPI, credential: String(decoding: tampered, as: UTF8.self)) }.map { error in
                #expect(!(error.localizedDescription.contains("fixture-key")))
            }
        }
        let longest = try APIUsageSource.xaiCredential(key: "fixture-key", teamID: String(repeating: "a", count: 128))
        #expect(throws: Never.self) { try APIUsageSource.makeRequest(provider: .xaiAPI, credential: longest) }
    }

    @Test
    func testXAIRejectsInvalidManagementKeysAndOverlongEncodedMaterial() {
        for key in ["", "fixture secret", "fixture\nHeader", "密钥", String(repeating: "a", count: 4097)] {
            #expect(throws: (any Error).self) { try APIUsageSource.xaiCredential(key: key, teamID: "fixture") }
        }
        #expect(throws: (any Error).self, "打包后的单条钥匙串材料也必须满足 4096 字节上限") { try APIUsageSource.xaiCredential(key: String(repeating: "a", count: 4096), teamID: "fixture") }
        for material in ["fixture-key", "{}", "[]", "{\"key\":\"fixture-key\"}", "{\"key\":12,\"teamID\":\"fixture\"}"] {
            #expect(throws: (any Error).self) { try APIUsageSource.makeRequest(provider: .xaiAPI, credential: material) }.map { error in
                #expect(!(error.localizedDescription.contains("fixture-key")))
            }
        }
    }

    @Test
    func testXAIUsesOfficialSignedUSDCentsLedgerWithoutInventingPercentage() throws {
        let purchase = try APIUsageSource.parse(provider: .xaiAPI, response: [
            "changes": [["changeOrigin": "PURCHASE", "amount": ["val": "-1000"]]],
            "total": ["val": "-1000"]
        ])
        #expect(purchase.balance == "USD 10.00")
        #expect(purchase.windows.isEmpty)
        let afterSpend = try APIUsageSource.parse(provider: .xaiAPI, response: ["total": ["val": "-2317"]])
        #expect(afterSpend.balance == "USD 23.17")
        let debt = try APIUsageSource.parse(provider: .xaiAPI, response: ["total": ["val": "100"]])
        #expect(debt.balance == "USD -1.00", "欠费不能取绝对值变成可用余额")
        let zero = try APIUsageSource.parse(provider: .xaiAPI, response: ["total": ["val": "0"]])
        #expect(zero.balance == "USD 0.00")
    }

    @Test
    func testXAIRejectsMissingOrMalformedLedgerCentsWithoutLeakingRemoteData() {
        for response: [String: Any] in [
            [:], ["total": [:]], ["total": ["val": true]], ["total": ["val": "nan"]],
            ["total": ["val": "1.5"]], ["total": ["val": "9223372036854775808"]],
            ["error": ["message": "fixture-management-secret"], "total": ["val": "0"]]
        ] {
            #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: .xaiAPI, response: response) }.map { error in
                #expect(!(error.localizedDescription.contains("fixture-management-secret")))
            }
        }
    }

    @Test
    func testErrorsNeverExposeCredentialOrRemoteResponse() {
        for credential in ["", "fixture-token\nsecret", "fixture token", String(repeating: "x", count: 4097)] {
            #expect(throws: (any Error).self) { try APIUsageSource.makeRequest(provider: .deepseekAPI, credential: credential) }.map { error in
                if !credential.isEmpty { #expect(!(error.localizedDescription.contains(credential))) }
            }
        }
        for provider: AIUsageProvider in [.deepseekAPI, .openrouterAPI, .kimiAPI, .minimaxAPI, .xaiAPI] {
            #expect(throws: (any Error).self) { try APIUsageSource.parse(provider: provider, response: ["error": ["message": "fixture-secret-response"]]) }.map { error in
                #expect(!(error.localizedDescription.contains("fixture-secret-response")))
            }
        }
    }
}
}
