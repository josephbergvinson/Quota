import Foundation
import XCTest
@testable import QuotaCore

final class ProviderParsingTests: XCTestCase {
    func testOpenAIUsageAndCostAreAggregatedWithoutInventingAllowance() async throws {
        let usageJSON = #"{"data":[{"start_time":1788134400,"results":[{"input_tokens":1200,"input_cached_tokens":300,"output_tokens":450,"num_model_requests":4,"model":"gpt-5"},{"input_tokens":100,"input_cached_tokens":0,"output_tokens":50,"num_model_requests":1,"model":"gpt-5-mini"}]}],"has_more":false,"next_page":null}"#
        let costJSON = #"{"data":[{"start_time":1788134400,"results":[{"amount":{"value":2.75,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#
        let client = StubHTTPClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-admin-key")
            if request.url?.path == "/v1/organization/costs" {
                return HTTPResponse(data: Data(costJSON.utf8), statusCode: 200)
            }
            XCTAssertEqual(request.url?.path, "/v1/organization/usage/completions")
            return HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
        }
        let provider = OpenAIUsageProvider(httpClient: client)
        let account = try makeAccount(kind: .openAIAPI)
        let credential = try ProviderCredential(secret: "secret-admin-key")

        let result = try await provider.fetchUsage(
            for: account,
            credential: credential,
            now: Date(timeIntervalSince1970: 1_788_192_000)
        )

        XCTAssertEqual(result.snapshot.inputTokens.value, 1_300)
        XCTAssertEqual(result.snapshot.cachedInputTokens.value, 300)
        XCTAssertEqual(result.snapshot.outputTokens.value, 500)
        XCTAssertEqual(result.snapshot.requests.value, 5)
        XCTAssertEqual(try XCTUnwrap(result.snapshot.costUSD.value), 2.75, accuracy: 0.0001)
        XCTAssertEqual(result.snapshot.modelUsage.value?.count, 2)
        XCTAssertEqual(result.snapshot.allowance.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.quotaWindows.unavailability?.reason, .notExposedByProvider)
    }

    func testNegativeProviderUsageIsRejected() async throws {
        let usageJSON = #"{"data":[{"start_time":1788134400,"results":[{"input_tokens":-1,"input_cached_tokens":0,"output_tokens":3,"model":"gpt-5"}]}],"has_more":false}"#
        let client = StubHTTPClient { _ in
            HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
        }
        let provider = OpenAIUsageProvider(httpClient: client)

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .openAIAPI),
                credential: ProviderCredential(secret: "secret-admin-key"),
                now: Date(timeIntervalSince1970: 1_788_192_000)
            )
            XCTFail("Expected malformed provider usage to be rejected")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMissingCachedInputTokensRejectsUsageInsteadOfRelabelingItUncached() async throws {
        let usageJSON = #"{"data":[{"start_time":1788134400,"results":[{"input_tokens":1200,"output_tokens":450,"num_model_requests":4,"model":"gpt-5"}]}],"has_more":false,"next_page":null}"#
        let client = StubHTTPClient { _ in
            HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
        }
        let provider = OpenAIUsageProvider(httpClient: client)

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .openAIAPI),
                credential: ProviderCredential(secret: "secret-admin-key"),
                now: Date(timeIntervalSince1970: 1_788_192_000)
            )
            XCTFail("Expected incomplete token usage to be rejected")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testOpenAICostAggregationDiscardsEarlierBucketsWhenLaterBucketIsInvalid() async throws {
        let usageJSON = #"{"data":[{"start_time":1788134400,"results":[{"input_tokens":1200,"input_cached_tokens":300,"output_tokens":450,"num_model_requests":4,"model":"gpt-5"}]}],"has_more":false,"next_page":null}"#
        let costJSON = #"{"data":[{"start_time":1788134400,"results":[{"amount":{"value":2.75,"currency":"usd"}}]},{"start_time":1788220800,"results":[{"amount":{"value":-0.5,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#
        let client = StubHTTPClient { request in
            if request.url?.path == "/v1/organization/costs" {
                return HTTPResponse(data: Data(costJSON.utf8), statusCode: 200)
            }
            return HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
        }
        let provider = OpenAIUsageProvider(httpClient: client)

        let result = try await provider.fetchUsage(
            for: makeAccount(kind: .openAIAPI),
            credential: ProviderCredential(secret: "secret-admin-key"),
            now: Date(timeIntervalSince1970: 1_788_192_000)
        )

        XCTAssertEqual(result.snapshot.totalTokens.value, 1_650)
        XCTAssertEqual(result.snapshot.costUSD.unavailability?.reason, .refreshFailed)
        XCTAssertEqual(
            result.warnings,
            ["Token usage loaded, but OpenAI cost data could not be refreshed."]
        )
        XCTAssertTrue(result.snapshot.dailyUsage.value?.allSatisfy { $0.costUSD == 0 } == true)
    }

    func testOpenAINonUSDCostMakesOnlyCostUnavailable() async throws {
        let usageJSON = #"{"data":[{"start_time":1788134400,"results":[{"input_tokens":1200,"input_cached_tokens":300,"output_tokens":450,"num_model_requests":4,"model":"gpt-5"}]}],"has_more":false,"next_page":null}"#
        let costJSON = #"{"data":[{"start_time":1788134400,"results":[{"amount":{"value":2.75,"currency":"usd"}},{"amount":{"value":1.25,"currency":"eur"}}]}],"has_more":false,"next_page":null}"#
        let client = StubHTTPClient { request in
            if request.url?.path == "/v1/organization/costs" {
                return HTTPResponse(data: Data(costJSON.utf8), statusCode: 200)
            }
            return HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
        }
        let provider = OpenAIUsageProvider(httpClient: client)

        let result = try await provider.fetchUsage(
            for: makeAccount(kind: .openAIAPI),
            credential: ProviderCredential(secret: "secret-admin-key"),
            now: Date(timeIntervalSince1970: 1_788_192_000)
        )

        XCTAssertEqual(result.snapshot.totalTokens.value, 1_650)
        XCTAssertEqual(result.snapshot.inputTokens.value, 1_200)
        XCTAssertEqual(result.snapshot.cachedInputTokens.value, 300)
        XCTAssertEqual(result.snapshot.outputTokens.value, 450)
        XCTAssertEqual(result.snapshot.costUSD.unavailability?.reason, .refreshFailed)
        XCTAssertEqual(
            result.warnings,
            ["Token usage loaded, but OpenAI cost data could not be refreshed."]
        )
        XCTAssertTrue(result.snapshot.dailyUsage.value?.allSatisfy { $0.costUSD == 0 } == true)
    }

    func testOpenAICostCancellationIsRethrown() async throws {
        let usageJSON = #"{"data":[{"start_time":1788134400,"results":[{"input_tokens":1200,"input_cached_tokens":0,"output_tokens":450,"model":"gpt-5"}]}],"has_more":false,"next_page":null}"#

        for useURLCancellation in [false, true] {
            let client = StubHTTPClient { request in
                if request.url?.path == "/v1/organization/costs" {
                    if useURLCancellation {
                        throw URLError(.cancelled)
                    }
                    throw CancellationError()
                }
                return HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
            }
            let provider = OpenAIUsageProvider(httpClient: client)

            do {
                _ = try await provider.fetchUsage(
                    for: makeAccount(kind: .openAIAPI),
                    credential: ProviderCredential(secret: "secret-admin-key"),
                    now: Date(timeIntervalSince1970: 1_788_192_000)
                )
                XCTFail("Expected cost refresh cancellation to be rethrown")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testOpenAIMissingRequestCountsRemainUnavailableAtEachAggregationLevel() async throws {
        let zeroRequestDate = Date(timeIntervalSince1970: 1_788_134_400)
        let mixedRequestDate = Date(timeIntervalSince1970: 1_788_220_800)
        let usageJSON = #"{"data":[{"start_time":1788134400,"results":[{"input_tokens":10,"input_cached_tokens":0,"output_tokens":5,"num_model_requests":0,"model":"gpt-zero"}]},{"start_time":1788220800,"results":[{"input_tokens":20,"input_cached_tokens":0,"output_tokens":10,"num_model_requests":3,"model":"gpt-mixed"},{"input_tokens":30,"input_cached_tokens":0,"output_tokens":15,"model":"gpt-mixed"}]}],"has_more":false,"next_page":null}"#
        let costJSON = #"{"data":[],"has_more":false,"next_page":null}"#
        let client = StubHTTPClient { request in
            if request.url?.path == "/v1/organization/costs" {
                return HTTPResponse(data: Data(costJSON.utf8), statusCode: 200)
            }
            return HTTPResponse(data: Data(usageJSON.utf8), statusCode: 200)
        }
        let provider = OpenAIUsageProvider(httpClient: client)

        let result = try await provider.fetchUsage(
            for: makeAccount(kind: .openAIAPI),
            credential: ProviderCredential(secret: "secret-admin-key"),
            now: Date(timeIntervalSince1970: 1_788_264_000)
        )

        let dailyUsage = try XCTUnwrap(result.snapshot.dailyUsage.value)
        XCTAssertEqual(dailyUsage.first { $0.date == zeroRequestDate }?.requests, 0)
        XCTAssertNil(dailyUsage.first { $0.date == mixedRequestDate }?.requests)

        let modelUsage = try XCTUnwrap(result.snapshot.modelUsage.value)
        XCTAssertEqual(modelUsage.first { $0.model == "gpt-zero" }?.requests, 0)
        XCTAssertNil(modelUsage.first { $0.model == "gpt-mixed" }?.requests)

        XCTAssertNil(result.snapshot.requests.value)
        XCTAssertEqual(result.snapshot.requests.unavailability?.reason, .notReturned)
    }

    func testProviderErrorMessageIsBoundedAndSingleLine() throws {
        let longMessage = String(repeating: "x", count: 400) + "\nsecret-looking-tail"
        let data = try JSONSerialization.data(withJSONObject: ["error": ["message": longMessage]])
        let error = ProviderError.from(response: HTTPResponse(data: data, statusCode: 401))

        guard case let .unexpectedStatus(code, message) = error else {
            return XCTFail("Expected HTTP provider error")
        }
        XCTAssertEqual(code, 401)
        XCTAssertEqual(message?.count, 300)
        XCTAssertFalse(message?.contains("\n") == true)
    }
}
