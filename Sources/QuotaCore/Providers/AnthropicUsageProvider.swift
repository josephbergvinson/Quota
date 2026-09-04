import Foundation

public struct AnthropicUsageProvider: UsageProvider {
    public let dataSourceKind: UsageDataSourceKind = .anthropicAdminAPI

    private let httpClient: any HTTPClient
    private let baseURL: URL
    private let maximumPages = 20

    public init(
        httpClient: any HTTPClient,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    public func fetchUsage(
        for account: ConnectedAccount,
        credential: ProviderCredential?,
        now: Date
    ) async throws -> ProviderFetchResult {
        guard account.kind == .anthropicAPI else {
            throw ProviderError.unsupportedAccount
        }
        guard let credential else {
            throw ProviderError.missingCredential
        }

        let queryWindow = try makeQueryWindow(endingAt: now)
        let usageBuckets = try await fetchUsageBuckets(
            credential: credential,
            window: queryWindow
        )

        var dailyAggregates: [Date: ProviderUsageAggregate] = [:]
        var modelAggregates: [String: ProviderUsageAggregate] = [:]
        for bucket in usageBuckets {
            let bucketDate = try validatedBucketDate(bucket, in: queryWindow)
            for result in bucket.results {
                let cacheCreationTokens = try checkedProviderSum([
                    result.cacheCreation.ephemeralFiveMinuteInputTokens,
                    result.cacheCreation.ephemeralOneHourInputTokens
                ])
                let inputTokens = try checkedProviderSum([
                    result.uncachedInputTokens,
                    cacheCreationTokens,
                    result.cacheReadInputTokens
                ])
                try dailyAggregates[bucketDate, default: ProviderUsageAggregate()].add(
                    inputTokens: inputTokens,
                    cachedInputTokens: result.cacheReadInputTokens,
                    outputTokens: result.outputTokens
                )

                let model = result.model?.nilIfBlank ?? "Unattributed"
                try modelAggregates[model, default: ProviderUsageAggregate()].add(
                    inputTokens: inputTokens,
                    cachedInputTokens: result.cacheReadInputTokens,
                    outputTokens: result.outputTokens
                )
            }
        }

        var warnings: [String] = []
        var dailyCosts: [Date: Decimal] = [:]
        let costMetric: Metric<Double>
        do {
            let costBuckets = try await fetchCostBuckets(
                credential: credential,
                window: queryWindow
            )
            var totalCostInCents = Decimal.zero
            for bucket in costBuckets {
                let bucketDate = try validatedBucketDate(bucket, in: queryWindow)
                for result in bucket.results {
                    guard result.currency.uppercased() == "USD" else {
                        throw ProviderError.invalidResponse
                    }
                    let amountInCents = try parseNonnegativeDecimal(result.amount)
                    dailyCosts[bucketDate] = try checkedDecimalAdd(
                        dailyCosts[bucketDate, default: .zero],
                        amountInCents
                    )
                    totalCostInCents = try checkedDecimalAdd(totalCostInCents, amountInCents)
                }
            }
            costMetric = .available(try dollars(fromCents: totalCostInCents))
        } catch {
            try Self.rethrowIfCancellation(error)
            // Cost is a single authoritative metric. If any bucket is malformed or
            // unavailable, discard partial aggregation instead of mixing it into
            // otherwise-valid daily token points.
            dailyCosts.removeAll(keepingCapacity: false)
            costMetric = .unavailable(
                UnavailableMetric(
                    reason: .refreshFailed,
                    detail: "Cost data was unavailable during this refresh."
                )
            )
            warnings.append("Token usage loaded, but Anthropic cost data could not be refreshed.")
        }

        for (date, amountInCents) in dailyCosts {
            try dailyAggregates[date, default: ProviderUsageAggregate()].add(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                costUSD: dollars(fromCents: amountInCents)
            )
        }

        let dailyUsage = try dailyAggregates
            .map { date, aggregate in
                _ = try aggregate.totalTokens()
                return DailyUsagePoint(
                    date: date,
                    inputTokens: aggregate.inputTokens,
                    cachedInputTokens: aggregate.cachedInputTokens,
                    outputTokens: aggregate.outputTokens,
                    requests: nil,
                    costUSD: aggregate.costUSD
                )
            }
            .sorted { $0.date < $1.date }

        let modelUsage = try modelAggregates
            .map { model, aggregate in
                _ = try aggregate.totalTokens()
                return ModelUsage(
                    model: model,
                    inputTokens: aggregate.inputTokens,
                    cachedInputTokens: aggregate.cachedInputTokens,
                    outputTokens: aggregate.outputTokens,
                    requests: nil
                )
            }
            .sorted {
                if $0.totalTokens == $1.totalTokens {
                    return $0.model.localizedStandardCompare($1.model) == .orderedAscending
                }
                return $0.totalTokens > $1.totalTokens
            }

        var totals = ProviderUsageAggregate()
        for aggregate in dailyAggregates.values {
            try totals.add(
                inputTokens: aggregate.inputTokens,
                cachedInputTokens: aggregate.cachedInputTokens,
                outputTokens: aggregate.outputTokens
            )
        }

        let capacityUnavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Anthropic's organization usage API reports activity and cost, not a live remaining allowance."
        )
        let resetUnavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Anthropic's organization reports do not provide a fixed capacity reset."
        )
        let requestsUnavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Anthropic's organization usage API does not report model-request counts."
        )

        return ProviderFetchResult(
            snapshot: UsageSnapshot(
                accountID: account.id,
                capturedAt: now,
                source: .anthropicAdminAPI,
                reportingPeriod: queryWindow.reportingPeriod,
                allowance: .unavailable(capacityUnavailable),
                quotaWindows: .unavailable(capacityUnavailable),
                resetAt: .unavailable(resetUnavailable),
                bankedResetCredits: .unavailable(
                    UnavailableMetric(
                        reason: .unsupportedForAccount,
                        detail: "Anthropic's organization reports do not expose banked reset credits."
                    )
                ),
                totalTokens: .available(try totals.totalTokens()),
                inputTokens: .available(totals.inputTokens),
                cachedInputTokens: .available(totals.cachedInputTokens),
                outputTokens: .available(totals.outputTokens),
                requests: .unavailable(requestsUnavailable),
                costUSD: costMetric,
                modelUsage: .available(modelUsage),
                dailyUsage: .available(dailyUsage)
            ),
            warnings: warnings
        )
    }

    private func fetchUsageBuckets(
        credential: ProviderCredential,
        window: QueryWindow
    ) async throws -> [AnthropicUsageBucket] {
        try await fetchPages(
            path: "/v1/organizations/usage_report/messages",
            credential: credential,
            window: window,
            additionalQueryItems: [URLQueryItem(name: "group_by[]", value: "model")],
            as: AnthropicUsagePage.self
        ) { $0.data }
    }

    private static func rethrowIfCancellation(_ error: Error) throws {
        if error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task.isCancelled
        {
            throw CancellationError()
        }
    }

    private func fetchCostBuckets(
        credential: ProviderCredential,
        window: QueryWindow
    ) async throws -> [AnthropicCostBucket] {
        try await fetchPages(
            path: "/v1/organizations/cost_report",
            credential: credential,
            window: window,
            additionalQueryItems: [],
            as: AnthropicCostPage.self
        ) { $0.data }
    }

    private func fetchPages<Page: AnthropicPage, Bucket>(
        path: String,
        credential: ProviderCredential,
        window: QueryWindow,
        additionalQueryItems: [URLQueryItem],
        as pageType: Page.Type,
        buckets: (Page) -> [Bucket]
    ) async throws -> [Bucket] {
        var collected: [Bucket] = []
        var pageToken: String?
        var seenPageTokens = Set<String>()

        for _ in 0..<maximumPages {
            var queryItems = commonQueryItems(for: window)
            queryItems.append(contentsOf: additionalQueryItems)
            if let pageToken {
                queryItems.append(URLQueryItem(name: "page", value: pageToken))
            }

            let response = try await send(
                path: path,
                queryItems: queryItems,
                credential: credential
            )
            let decoded: Page = try decode(response, as: pageType)
            collected.append(contentsOf: buckets(decoded))
            guard decoded.hasMore else { return collected }
            guard
                let nextPage = decoded.nextPage?.nilIfBlank,
                seenPageTokens.insert(nextPage).inserted
            else {
                throw ProviderError.invalidResponse
            }
            pageToken = nextPage
        }

        throw ProviderError.paginationLimitReached
    }

    private func send(
        path: String,
        queryItems: [URLQueryItem],
        credential: ProviderCredential
    ) async throws -> HTTPResponse {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderError.invalidURL
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(credential.secret, forHTTPHeaderField: "x-api-key")
        request.setValue(
            "Quota/1.0 (https://github.com/josephbergvinson/Quota)",
            forHTTPHeaderField: "User-Agent"
        )

        let response = try await httpClient.send(request)
        if let error = ProviderError.from(response: response) {
            throw error
        }
        return response
    }

    private func decode<Value: Decodable>(
        _ response: HTTPResponse,
        as type: Value.Type
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    private func commonQueryItems(for window: QueryWindow) -> [URLQueryItem] {
        [
            URLQueryItem(name: "starting_at", value: rfc3339(window.reportingPeriod.start)),
            URLQueryItem(name: "ending_at", value: rfc3339(window.queryEnd)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
    }

    private func makeQueryWindow(endingAt now: Date) throws -> QueryWindow {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ProviderError.invalidResponse
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startOfToday = calendar.startOfDay(for: now)
        guard
            let start = calendar.date(byAdding: .day, value: -29, to: startOfToday),
            let queryEnd = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        else {
            throw ProviderError.invalidResponse
        }
        return QueryWindow(
            reportingPeriod: try ReportingPeriod(start: start, end: now),
            queryEnd: queryEnd
        )
    }

    private func validatedBucketDate(
        _ bucket: some AnthropicTimeBucket,
        in window: QueryWindow
    ) throws -> Date {
        guard
            let start = parseRFC3339(bucket.startingAt),
            let end = parseRFC3339(bucket.endingAt),
            end > start,
            start >= window.reportingPeriod.start,
            start < window.queryEnd,
            end <= window.queryEnd
        else {
            throw ProviderError.invalidResponse
        }
        return start
    }

    private func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func parseNonnegativeDecimal(_ value: String) throws -> Decimal {
        guard
            let decimal = Decimal(
                string: value,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            decimal >= .zero
        else {
            throw ProviderError.invalidResponse
        }
        return decimal
    }

    private func checkedDecimalAdd(_ left: Decimal, _ right: Decimal) throws -> Decimal {
        var left = left
        var right = right
        var result = Decimal()
        let calculationError = NSDecimalAdd(&result, &left, &right, .plain)
        guard calculationError == .noError, !result.isNaN, result >= .zero else {
            throw ProviderError.invalidResponse
        }
        return result
    }

    private func dollars(fromCents cents: Decimal) throws -> Double {
        var cents = cents
        var divisor = Decimal(100)
        var dollars = Decimal()
        let calculationError = NSDecimalDivide(&dollars, &cents, &divisor, .plain)
        let value = NSDecimalNumber(decimal: dollars).doubleValue
        guard
            calculationError == .noError,
            !dollars.isNaN,
            value.isFinite,
            value >= 0
        else {
            throw ProviderError.invalidResponse
        }
        return value
    }
}

private struct QueryWindow {
    let reportingPeriod: ReportingPeriod
    let queryEnd: Date
}

private protocol AnthropicPage: Decodable {
    var hasMore: Bool { get }
    var nextPage: String? { get }
}

private protocol AnthropicTimeBucket {
    var startingAt: String { get }
    var endingAt: String { get }
}

private struct AnthropicUsagePage: AnthropicPage {
    let data: [AnthropicUsageBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct AnthropicUsageBucket: Decodable, AnthropicTimeBucket {
    let startingAt: String
    let endingAt: String
    let results: [AnthropicUsageResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct AnthropicUsageResult: Decodable {
    let uncachedInputTokens: Int
    let cacheCreation: AnthropicCacheCreation
    let cacheReadInputTokens: Int
    let outputTokens: Int
    let model: String?

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheCreation = "cache_creation"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case model
    }
}

private struct AnthropicCacheCreation: Decodable {
    let ephemeralFiveMinuteInputTokens: Int
    let ephemeralOneHourInputTokens: Int

    enum CodingKeys: String, CodingKey {
        case ephemeralFiveMinuteInputTokens = "ephemeral_5m_input_tokens"
        case ephemeralOneHourInputTokens = "ephemeral_1h_input_tokens"
    }
}

private struct AnthropicCostPage: AnthropicPage {
    let data: [AnthropicCostBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct AnthropicCostBucket: Decodable, AnthropicTimeBucket {
    let startingAt: String
    let endingAt: String
    let results: [AnthropicCostResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct AnthropicCostResult: Decodable {
    let amount: String
    let currency: String
}

private extension String {
    var nilIfBlank: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
