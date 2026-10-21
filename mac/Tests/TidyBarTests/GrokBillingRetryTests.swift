import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class GrokBillingRetryTests {
    private func credential() throws -> GrokBuildUsageSource.Credential {
        let date = ISO8601DateFormatter()
        let value: [String: Any] = ["https://auth.x.ai::retry-test": [
            "auth_mode": "oidc", "oidc_issuer": "https://auth.x.ai", "oidc_client_id": "retry-test",
            "key": "synthetic-retry-token", "user_id": "synthetic-retry-user",
            "create_time": date.string(from: Date().addingTimeInterval(-60)),
            "expires_at": date.string(from: Date().addingTimeInterval(3600))]]
        return try #require(try GrokBuildUsageSource.credential(from: JSONSerialization.data(withJSONObject: value)))
    }

    private func response(_ request: URLRequest, status: Int, body: String = "") -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @Test
    func testTransientServiceFailureRetriesOnlyTheFixedReadOnlyBillingRequest() async throws {
        var calls = 0
        let snapshot = try await GrokBuildUsageSource.fetchBilling(credential()) { request in
            calls += 1
            #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-retry-token")
            #expect(request.value(forHTTPHeaderField: "x-userid") == "synthetic-retry-user")
            if calls == 1 { return self.response(request, status: 503, body: "private server response must be discarded") }
            return self.response(request, status: 200, body: #"{"config":{"creditUsagePercent":37}}"#)
        }
        #expect(calls == 2)
        #expect(snapshot.windows.first?.remainingPercent == 63)
        #expect(snapshot.isConnected)
    }

    @Test
    func testPersistentOutageStopsAfterOneRetryAndDoesNotDiscloseResponseOrRequestLogin() async throws {
        for status in [502, 503, 504] {
            var calls = 0
            do {
                _ = try await GrokBuildUsageSource.fetchBilling(credential()) { request in
                    calls += 1
                    return self.response(request, status: status, body: "synthetic-private-upstream-detail")
                }
                Issue.record("Persistent billing outage must remain an error")
            } catch {
                #expect(error.localizedDescription.contains("\(status)"))
                #expect(error.localizedDescription.contains("无需重新登录"))
                #expect(!(error.localizedDescription.contains("synthetic")))
            }
            #expect(calls == 2)
        }
    }

    @Test
    func testAuthenticationRateLimitAndMalformedResponsesDoNotRetry() async throws {
        for status in [401, 403, 429, 200] {
            var calls = 0
            do {
                _ = try await GrokBuildUsageSource.fetchBilling(credential()) { request in
                    calls += 1
                    return self.response(request, status: status, body: "not-json-private-response")
                }
                Issue.record("Unusable billing data must fail")
            } catch { #expect(!(error.localizedDescription.contains("private-response"))) }
            #expect(calls == 1)
        }
    }

    @Test
    func testCancellationBetweenAttemptsPreventsTheSecondRequest() async throws {
        let firstResponse = TestSignal()
        var calls = 0
        let task = Task {
            try await GrokBuildUsageSource.fetchBilling(credential()) { request in
                calls += 1
                firstResponse.signal()
                return self.response(request, status: 503)
            }
        }
        #expect(await firstResponse.wait(timeout: 2))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled refresh must stop") }
        catch { #expect(error is CancellationError) }
        #expect(calls == 1)
    }

    @Test
    func testUnexpectedDestinationCannotTriggerRetryOrParseSuccessfulData() async throws {
        var calls = 0
        do {
            _ = try await GrokBuildUsageSource.fetchBilling(credential()) { _ in
                calls += 1
                return (Data(#"{"config":{"creditUsagePercent":37}}"#.utf8),
                    HTTPURLResponse(url: URL(string: "https://example.test/v1/billing")!, statusCode: 503,
                        httpVersion: nil, headerFields: nil)!)
            }
            Issue.record("An unexpected response destination must be rejected")
        } catch { #expect(error.localizedDescription.contains("非预期地址")) }
        #expect(calls == 1)
    }
}
}

private final class BillingStreamProtocol: URLProtocol {
    static var stopped = TestSignal()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Fixture-Status") ?? "200")!
        let count = Int(request.value(forHTTPHeaderField: "X-Fixture-Length") ?? "1048577")!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 32, count: 65_536)
        for _ in 0..<(count / chunk.count) { client?.urlProtocol(self, didLoad: chunk) }
        if count % chunk.count != 0 { client?.urlProtocol(self, didLoad: Data(repeating: 32, count: count % chunk.count)) }
        // Oversized responses deliberately never finish: the reader must cancel immediately.
        if count <= 1_048_576 { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() { Self.stopped.signal() }
}

extension TidyBarTests.GrokBillingRetryTests {
    @Test func streamedBillingCancelsOversizedBodiesForEveryStatusWithoutRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingStreamProtocol.self]
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for status in [200, 302, 401, 403, 429, 502, 503, 504] {
            BillingStreamProtocol.stopped = TestSignal()
            var calls = 0
            var hitLimit = false
            do {
                _ = try await GrokBuildUsageSource.fetchBilling(credential()) { request in
                    calls += 1
                    var request = request
                    request.setValue(String(status), forHTTPHeaderField: "X-Fixture-Status")
                    do { return try await GrokBuildUsageSource.loadBilling(request, session: session) }
                    catch AIUsageError.invalidResponse {
                        hitLimit = true
                        throw AIUsageError.invalidResponse
                    }
                }
                Issue.record("Oversized billing body must fail for every status")
            } catch { #expect(error is AIUsageError) }
            #expect(calls == 1)
            #expect(hitLimit) // A request timeout must not masquerade as a size-limit rejection.
            #expect(await BillingStreamProtocol.stopped.wait(timeout: 1))
        }
    }

    @Test func streamedBillingAcceptsExactlyOneMiB() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://example.test/billing")!)
        request.setValue("1048576", forHTTPHeaderField: "X-Fixture-Length")
        let (data, _) = try await GrokBuildUsageSource.loadBilling(request, session: session)
        #expect(data.count == 1_048_576)
    }
}
