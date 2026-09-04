import Foundation
import Testing
@testable import QuotaCore

@Suite("Anthropic Admin usage provider")
struct AnthropicUsageProviderTests {
    @Test("Aggregates daily and model token usage and converts cost cents to dollars")
    func aggregatesDailyAndModelUsageAndConvertsCostCentsToDollars() async throws {
        let usageJSON = #"""
        {
          "data": [{
            "starting_at": "2026-09-04T00:00:00Z",
            "ending_at": "2026-09-05T00:00:00Z",
            "results": [
              {
                "uncached_input_tokens": 100,
                "cache_creation": {
                  "ephemeral_5m_input_tokens": 20,
                  "ephemeral_1h_input_tokens": 30
                },
                "cache_read_input_tokens": 40,
                "output_tokens": 50,
                "model": "claude-opus-5"
              },
              {
                "uncached_input_tokens": 10,
                "cache_creation": {
                  "ephemeral_5m_input_tokens": 0,
                  "ephemeral_1h_input_tokens": 0
                },
                "cache_read_input_tokens": 5,
                "output_tokens": 7,
                "model": "claude-sonnet-5"
              }
            ]
          }],
          "has_more": false,
          "next_page": null
        }
        """#
        let costJSON = #"""
        {
          "data": [{
            "starting_at": "2026-09-04T00:00:00Z",
            "ending_at": "2026-09-05T00:00:00Z",
            "results": [
              {"amount": "123.456", "currency": "USD"},
              {"amount": "76.544", "currency": "USD"}
            ]
          }],
          "has_more": false,
          "next_page": null
        }
        """#
        let client = URLProtocolMockHTTPClient { request in
            if request.url?.path == "/v1/organizations/cost_report" {
                return .json(costJSON)
            }
            return .json(usageJSON)
        }
        let provider = AnthropicUsageProvider(httpClient: client)
        let account = try makeAccount(kind: .anthropicAPI)

        let result = try await provider.fetchUsage(
            for: account,
            credential: ProviderCredential(secret: "sk-ant-admin-test"),
            now: try date("2026-09-04T18:00:00Z")
        )

        #expect(result.snapshot.source == .anthropicAdminAPI)
        #expect(result.snapshot.totalTokens.value == 262)
        #expect(result.snapshot.inputTokens.value == 205)
        #expect(result.snapshot.cachedInputTokens.value == 45)
        #expect(result.snapshot.outputTokens.value == 57)
        #expect(result.snapshot.requests.value == nil)
        #expect(result.snapshot.requests.unavailability?.reason == .notExposedByProvider)
        let totalCost = try #require(result.snapshot.costUSD.value)
        #expect(abs(totalCost - 2) < 0.000_001)
        #expect(result.snapshot.allowance.unavailability?.reason == .notExposedByProvider)
        #expect(result.snapshot.quotaWindows.unavailability?.reason == .notExposedByProvider)
        #expect(result.snapshot.resetAt.unavailability?.reason == .notExposedByProvider)
        #expect(result.snapshot.bankedResetCredits.unavailability?.reason == .unsupportedForAccount)
        #expect(result.warnings.isEmpty)

        let daily = try #require(result.snapshot.dailyUsage.value)
        #expect(daily.count == 1)
        #expect(daily[0].inputTokens == 205)
        #expect(daily[0].cachedInputTokens == 45)
        #expect(daily[0].outputTokens == 57)
        #expect(daily[0].requests == nil)
        #expect(abs(daily[0].costUSD - 2) < 0.000_001)

        let models = try #require(result.snapshot.modelUsage.value)
        #expect(models.map(\.model) == ["claude-opus-5", "claude-sonnet-5"])
        #expect(models.map(\.totalTokens) == [240, 22])
        #expect(models.allSatisfy { $0.requests == nil })

        let requests = client.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-admin-test")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Quota/") == true)
            let requestURL = try #require(request.url)
            let items = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first(where: { $0.name == "starting_at" })?.value == "2026-08-06T00:00:00Z")
            #expect(items?.first(where: { $0.name == "ending_at" })?.value == "2026-09-05T00:00:00Z")
            #expect(items?.first(where: { $0.name == "bucket_width" })?.value == "1d")
            #expect(items?.first(where: { $0.name == "limit" })?.value == "31")
        }
        let usageRequest = try #require(
            requests.first { $0.url?.path == "/v1/organizations/usage_report/messages" }
        )
        let usageRequestURL = try #require(usageRequest.url)
        let usageItems = URLComponents(
            url: usageRequestURL,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(usageItems?.first(where: { $0.name == "group_by[]" })?.value == "model")
    }

    @Test("Paginates usage without repeating or dropping buckets")
    func paginatesUsageWithoutRepeatingOrDroppingBuckets() async throws {
        let firstUsagePage = usagePage(
            startingAt: "2026-09-03T00:00:00Z",
            endingAt: "2026-09-04T00:00:00Z",
            uncachedInputTokens: 10,
            outputTokens: 2,
            hasMore: true,
            nextPage: "page_two"
        )
        let secondUsagePage = usagePage(
            startingAt: "2026-09-04T00:00:00Z",
            endingAt: "2026-09-05T00:00:00Z",
            uncachedInputTokens: 20,
            outputTokens: 3,
            hasMore: false,
            nextPage: nil
        )
        let emptyCostPage = #"{"data":[],"has_more":false,"next_page":null}"#
        let client = URLProtocolMockHTTPClient { request in
            guard request.url?.path == "/v1/organizations/usage_report/messages" else {
                return .json(emptyCostPage)
            }
            guard let requestURL = request.url else {
                throw URLError(.badURL)
            }
            let page = URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "page" })?.value
            return .json(page == "page_two" ? secondUsagePage : firstUsagePage)
        }

        let result = try await AnthropicUsageProvider(httpClient: client).fetchUsage(
            for: makeAccount(kind: .anthropicAPI),
            credential: ProviderCredential(secret: "sk-ant-admin-test"),
            now: try date("2026-09-04T18:00:00Z")
        )

        #expect(result.snapshot.totalTokens.value == 35)
        #expect(result.snapshot.dailyUsage.value?.count == 2)
        let usageRequests = client.requests.filter {
            $0.url?.path == "/v1/organizations/usage_report/messages"
        }
        #expect(usageRequests.count == 2)
        let lastUsageURL = try #require(usageRequests.last?.url)
        let secondItems = URLComponents(
            url: lastUsageURL,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(secondItems?.first(where: { $0.name == "page" })?.value == "page_two")
    }

    @Test("Rejects a repeated pagination cursor")
    func repeatedPaginationCursorFailsClosed() async throws {
        let page = usagePage(
            startingAt: "2026-09-04T00:00:00Z",
            endingAt: "2026-09-05T00:00:00Z",
            uncachedInputTokens: 1,
            outputTokens: 1,
            hasMore: true,
            nextPage: "same_page"
        )
        let client = URLProtocolMockHTTPClient { _ in .json(page) }

        do {
            _ = try await AnthropicUsageProvider(httpClient: client).fetchUsage(
                for: makeAccount(kind: .anthropicAPI),
                credential: ProviderCredential(secret: "sk-ant-admin-test"),
                now: try date("2026-09-04T18:00:00Z")
            )
            Issue.record("Expected a repeated cursor to be rejected")
        } catch let error as ProviderError {
            #expect(error == .invalidResponse)
        }
        #expect(client.requests.count == 2)
    }

    @Test("Cost failure preserves authoritative token usage")
    func costFailurePreservesAuthoritativeTokenUsage() async throws {
        let usageJSON = usagePage(
            startingAt: "2026-09-04T00:00:00Z",
            endingAt: "2026-09-05T00:00:00Z",
            uncachedInputTokens: 8,
            outputTokens: 5,
            hasMore: false,
            nextPage: nil
        )
        let client = URLProtocolMockHTTPClient { request in
            if request.url?.path == "/v1/organizations/cost_report" {
                return .json(#"{"error":{"message":"cost unavailable"}}"#, statusCode: 503)
            }
            return .json(usageJSON)
        }

        let result = try await AnthropicUsageProvider(httpClient: client).fetchUsage(
            for: makeAccount(kind: .anthropicAPI),
            credential: ProviderCredential(secret: "sk-ant-admin-test"),
            now: try date("2026-09-04T18:00:00Z")
        )

        #expect(result.snapshot.totalTokens.value == 13)
        #expect(result.snapshot.costUSD.unavailability?.reason == .refreshFailed)
        #expect(result.warnings == ["Token usage loaded, but Anthropic cost data could not be refreshed."])
    }

    @Test("Cancellation during cost loading cancels the whole refresh")
    func cancellationDuringCostLoadingCancelsWholeRefresh() async throws {
        let usageJSON = usagePage(
            startingAt: "2026-09-04T00:00:00Z",
            endingAt: "2026-09-05T00:00:00Z",
            uncachedInputTokens: 8,
            outputTokens: 5,
            hasMore: false,
            nextPage: nil
        )
        let client = SuspendingAnthropicCostHTTPClient(usageJSON: usageJSON)
        let provider = AnthropicUsageProvider(httpClient: client)
        let account = try makeAccount(kind: .anthropicAPI)
        let now = try date("2026-09-04T18:00:00Z")
        let refresh = Task {
            try await provider.fetchUsage(
                for: account,
                credential: ProviderCredential(secret: "sk-ant-admin-test"),
                now: now
            )
        }

        await client.waitUntilCostStarts()
        refresh.cancel()

        do {
            _ = try await refresh.value
            Issue.record("Expected cancellation to abort the entire refresh")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Rejects negative usage before requesting cost")
    func rejectsNegativeUsageAndDoesNotRequestCost() async throws {
        let usageJSON = usagePage(
            startingAt: "2026-09-04T00:00:00Z",
            endingAt: "2026-09-05T00:00:00Z",
            uncachedInputTokens: -1,
            outputTokens: 2,
            hasMore: false,
            nextPage: nil
        )
        let client = URLProtocolMockHTTPClient { _ in .json(usageJSON) }

        do {
            _ = try await AnthropicUsageProvider(httpClient: client).fetchUsage(
                for: makeAccount(kind: .anthropicAPI),
                credential: ProviderCredential(secret: "sk-ant-admin-test"),
                now: try date("2026-09-04T18:00:00Z")
            )
            Issue.record("Expected malformed usage to be rejected")
        } catch let error as ProviderError {
            #expect(error == .invalidResponse)
        }
        #expect(client.requests.map { $0.url?.path } == ["/v1/organizations/usage_report/messages"])
    }

    @Test("Invalid cost amount is unavailable rather than fabricated")
    func invalidCostAmountIsUnavailableRatherThanFabricated() async throws {
        let usageJSON = usagePage(
            startingAt: "2026-09-04T00:00:00Z",
            endingAt: "2026-09-05T00:00:00Z",
            uncachedInputTokens: 3,
            outputTokens: 4,
            hasMore: false,
            nextPage: nil
        )
        let costJSON = #"""
        {
          "data": [{
            "starting_at": "2026-09-04T00:00:00Z",
            "ending_at": "2026-09-05T00:00:00Z",
            "results": [
              {"amount": "100", "currency": "USD"},
              {"amount": "not-a-number", "currency": "USD"}
            ]
          }],
          "has_more": false,
          "next_page": null
        }
        """#
        let client = URLProtocolMockHTTPClient { request in
            request.url?.path == "/v1/organizations/cost_report"
                ? .json(costJSON)
                : .json(usageJSON)
        }

        let result = try await AnthropicUsageProvider(httpClient: client).fetchUsage(
            for: makeAccount(kind: .anthropicAPI),
            credential: ProviderCredential(secret: "sk-ant-admin-test"),
            now: try date("2026-09-04T18:00:00Z")
        )

        #expect(result.snapshot.totalTokens.value == 7)
        #expect(result.snapshot.costUSD.value == nil)
        #expect(result.snapshot.costUSD.unavailability?.reason == .refreshFailed)
        #expect(result.snapshot.dailyUsage.value?.first?.costUSD == 0)
    }

    @Test("Requires an Anthropic API account and admin key")
    func requiresAnthropicAPIAccountAndCredential() async throws {
        let client = URLProtocolMockHTTPClient { _ in
            .json(#"{"data":[],"has_more":false,"next_page":null}"#)
        }
        let provider = AnthropicUsageProvider(httpClient: client)

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .openAIAPI),
                credential: ProviderCredential(secret: "sk-ant-admin-test"),
                now: try date("2026-09-04T18:00:00Z")
            )
            Issue.record("Expected an unsupported account error")
        } catch let error as ProviderError {
            #expect(error == .unsupportedAccount)
        }

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .anthropicAPI),
                credential: nil,
                now: try date("2026-09-04T18:00:00Z")
            )
            Issue.record("Expected a missing credential error")
        } catch let error as ProviderError {
            #expect(error == .missingCredential)
        }
        #expect(client.requests.isEmpty)
    }

    private func usagePage(
        startingAt: String,
        endingAt: String,
        uncachedInputTokens: Int,
        outputTokens: Int,
        hasMore: Bool,
        nextPage: String?
    ) -> String {
        let nextPageJSON = nextPage.map { "\"\($0)\"" } ?? "null"
        return #"""
        {
          "data": [{
            "starting_at": "\#(startingAt)",
            "ending_at": "\#(endingAt)",
            "results": [{
              "uncached_input_tokens": \#(uncachedInputTokens),
              "cache_creation": {
                "ephemeral_5m_input_tokens": 0,
                "ephemeral_1h_input_tokens": 0
              },
              "cache_read_input_tokens": 0,
              "output_tokens": \#(outputTokens),
              "model": "claude-sonnet-5"
            }]
          }],
          "has_more": \#(hasMore),
          "next_page": \#(nextPageJSON)
        }
        """#
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: value))
    }
}

private struct MockHTTPResponse {
    let data: Data
    let statusCode: Int

    static func json(_ value: String, statusCode: Int = 200) -> MockHTTPResponse {
        MockHTTPResponse(data: Data(value.utf8), statusCode: statusCode)
    }
}

private actor SuspendingAnthropicCostHTTPClient: HTTPClient {
    private let usageResponse: HTTPResponse
    private var costStarted = false
    private var costWaiters: [CheckedContinuation<Void, Never>] = []

    init(usageJSON: String) {
        usageResponse = HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
    }

    func waitUntilCostStarts() async {
        guard !costStarted else { return }
        await withCheckedContinuation { continuation in
            costWaiters.append(continuation)
        }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.path == "/v1/organizations/cost_report" else {
            return usageResponse
        }

        costStarted = true
        let waiters = costWaiters
        costWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}

private final class URLProtocolMockHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) throws -> MockHTTPResponse

    private let identifier = UUID().uuidString
    private let session: URLSession
    private let state: URLProtocolMockState

    init(responder: @escaping Responder) {
        state = URLProtocolMockState(responder: responder)
        URLProtocolMockRegistry.shared.register(state, for: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaMockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
        URLProtocolMockRegistry.shared.unregister(identifier)
    }

    var requests: [URLRequest] {
        state.requests
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        var request = request
        request.setValue(identifier, forHTTPHeaderField: QuotaMockURLProtocol.identifierHeader)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidHTTPResponse
        }
        return HTTPResponse(data: data, statusCode: httpResponse.statusCode)
    }
}

private final class URLProtocolMockState: @unchecked Sendable {
    private let lock = NSLock()
    private let responder: URLProtocolMockHTTPClient.Responder
    private var capturedRequests: [URLRequest] = []

    init(responder: @escaping URLProtocolMockHTTPClient.Responder) {
        self.responder = responder
    }

    var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    func respond(to request: URLRequest) throws -> MockHTTPResponse {
        lock.withLock { capturedRequests.append(request) }
        return try responder(request)
    }
}

private final class URLProtocolMockRegistry: @unchecked Sendable {
    static let shared = URLProtocolMockRegistry()

    private let lock = NSLock()
    private var states: [String: URLProtocolMockState] = [:]

    func register(_ state: URLProtocolMockState, for identifier: String) {
        lock.withLock { states[identifier] = state }
    }

    func unregister(_ identifier: String) {
        lock.withLock { states[identifier] = nil }
    }

    func state(for identifier: String) -> URLProtocolMockState? {
        lock.withLock { states[identifier] }
    }
}

private final class QuotaMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let identifierHeader = "X-Quota-Test-Identifier"

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: identifierHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let identifier = request.value(forHTTPHeaderField: Self.identifierHeader),
            let state = URLProtocolMockRegistry.shared.state(for: identifier),
            let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let result = try state.respond(to: request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
