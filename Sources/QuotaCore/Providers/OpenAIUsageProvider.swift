import Foundation

public struct OpenAIUsageProvider: UsageProvider {
    public let dataSourceKind: UsageDataSourceKind = .openAIAdminAPI

    private let httpClient: any HTTPClient
    private let baseURL: URL
    private let maximumPages = 20

    public init(
        httpClient: any HTTPClient,
        baseURL: URL = URL(string: "https://api.openai.com")!
    ) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    public func fetchUsage(
        for account: ConnectedAccount,
        credential: ProviderCredential?,
        now: Date
    ) async throws -> ProviderFetchResult {
        guard account.kind == .openAIAPI else {
            throw ProviderError.unsupportedAccount
        }
        guard let credential else {
            throw ProviderError.missingCredential
        }

        let period = try reportingPeriod(endingAt: now)
        let usageBuckets = try await fetchUsageBuckets(
            account: account,
            credential: credential,
            period: period
        )

        var dailyAggregates: [Date: ProviderUsageAggregate] = [:]
        var modelAggregates: [String: ProviderUsageAggregate] = [:]
        var dailyRequestCounts: [Date: OpenAIRequestCountAggregate] = [:]
        var modelRequestCounts: [String: OpenAIRequestCountAggregate] = [:]
        var totalRequestCount = OpenAIRequestCountAggregate()

        for bucket in usageBuckets {
            let date = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            for result in bucket.results {
                let inputTokens = result.inputTokens
                let cachedInputTokens = result.inputCachedTokens
                let outputTokens = result.outputTokens
                try dailyAggregates[date, default: ProviderUsageAggregate()].add(
                    inputTokens: inputTokens,
                    cachedInputTokens: cachedInputTokens,
                    outputTokens: outputTokens
                )
                try dailyRequestCounts[date, default: OpenAIRequestCountAggregate()].add(
                    result.requestCount
                )

                let model = result.model?.nilIfBlank ?? "Unattributed"
                try modelAggregates[model, default: ProviderUsageAggregate()].add(
                    inputTokens: inputTokens,
                    cachedInputTokens: cachedInputTokens,
                    outputTokens: outputTokens
                )
                try modelRequestCounts[model, default: OpenAIRequestCountAggregate()].add(
                    result.requestCount
                )
                try totalRequestCount.add(result.requestCount)
            }
        }

        var warnings: [String] = []
        let costMetric: Metric<Double>
        var dailyCosts: [Date: Double] = [:]
        do {
            let costBuckets = try await fetchCostBuckets(
                account: account,
                credential: credential,
                period: period
            )
            var totalCost = 0.0
            for bucket in costBuckets {
                let date = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
                var dailyCost = 0.0
                for result in bucket.results {
                    guard result.amount.currency.uppercased() == "USD" else {
                        throw ProviderError.invalidResponse
                    }
                    dailyCost = try checkedProviderCostSum(dailyCost, result.amount.value.value)
                }
                totalCost = try checkedProviderCostSum(totalCost, dailyCost)
                dailyCosts[date] = try checkedProviderCostSum(
                    dailyCosts[date] ?? 0,
                    dailyCost
                )
            }
            costMetric = .available(totalCost)
        } catch {
            try Self.rethrowIfCancellation(error)
            dailyCosts.removeAll(keepingCapacity: false)
            costMetric = .unavailable(
                UnavailableMetric(
                    reason: .refreshFailed,
                    detail: "Cost data was unavailable during this refresh."
                )
            )
            warnings.append("Token usage loaded, but OpenAI cost data could not be refreshed.")
        }
        for (date, dailyCost) in dailyCosts {
            try dailyAggregates[date, default: ProviderUsageAggregate()].add(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                costUSD: dailyCost
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
                    requests: dailyRequestCounts[date]?.value,
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
                    requests: modelRequestCounts[model]?.value
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

        let allowanceUnavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "OpenAI's organization usage API reports activity and cost, not a live remaining allowance."
        )
        let resetUnavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "OpenAI's organization usage API does not provide a subscription reset time."
        )
        let requestsMetric: Metric<Int> = totalRequestCount.value.map(Metric.available)
            ?? .unavailable(
                UnavailableMetric(
                    reason: .notReturned,
                    detail: "OpenAI did not return a request count for every usage result."
                )
            )

        return ProviderFetchResult(
            snapshot: UsageSnapshot(
                accountID: account.id,
                capturedAt: now,
                source: .openAIAdminAPI,
                reportingPeriod: period,
                allowance: .unavailable(allowanceUnavailable),
                quotaWindows: .unavailable(allowanceUnavailable),
                resetAt: .unavailable(resetUnavailable),
                bankedResetCredits: .unavailable(
                    UnavailableMetric(
                        reason: .unsupportedForAccount,
                        detail: "Banked resets belong to ChatGPT accounts, not API organizations."
                    )
                ),
                totalTokens: .available(try totals.totalTokens()),
                inputTokens: .available(totals.inputTokens),
                cachedInputTokens: .available(totals.cachedInputTokens),
                outputTokens: .available(totals.outputTokens),
                requests: requestsMetric,
                costUSD: costMetric,
                modelUsage: .available(modelUsage),
                dailyUsage: .available(dailyUsage)
            ),
            warnings: warnings
        )
    }

    private static func rethrowIfCancellation(_ error: Error) throws {
        if error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task.isCancelled
        {
            throw CancellationError()
        }
    }

    private func fetchUsageBuckets(
        account: ConnectedAccount,
        credential: ProviderCredential,
        period: ReportingPeriod
    ) async throws -> [OpenAIUsageBucket] {
        var buckets: [OpenAIUsageBucket] = []
        var page: String?

        for _ in 0..<maximumPages {
            var queryItems = commonQueryItems(for: period)
            queryItems.append(URLQueryItem(name: "group_by", value: "model"))
            if let page {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }

            let response = try await send(
                path: "/v1/organization/usage/completions",
                queryItems: queryItems,
                account: account,
                credential: credential
            )
            let decoded: OpenAIUsagePage = try decode(response)
            buckets.append(contentsOf: decoded.data)
            guard decoded.hasMore == true else { return buckets }
            guard let nextPage = decoded.nextPage?.nilIfBlank else {
                throw ProviderError.invalidResponse
            }
            page = nextPage
        }

        throw ProviderError.paginationLimitReached
    }

    private func fetchCostBuckets(
        account: ConnectedAccount,
        credential: ProviderCredential,
        period: ReportingPeriod
    ) async throws -> [OpenAICostBucket] {
        var buckets: [OpenAICostBucket] = []
        var page: String?

        for _ in 0..<maximumPages {
            var queryItems = commonQueryItems(for: period)
            if let page {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }

            let response = try await send(
                path: "/v1/organization/costs",
                queryItems: queryItems,
                account: account,
                credential: credential
            )
            let decoded: OpenAICostPage = try decode(response)
            buckets.append(contentsOf: decoded.data)
            guard decoded.hasMore == true else { return buckets }
            guard let nextPage = decoded.nextPage?.nilIfBlank else {
                throw ProviderError.invalidResponse
            }
            page = nextPage
        }

        throw ProviderError.paginationLimitReached
    }

    private func send(
        path: String,
        queryItems: [URLQueryItem],
        account: ConnectedAccount,
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
        request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
        if let organizationIdentifier = account.organizationIdentifier {
            request.setValue(organizationIdentifier, forHTTPHeaderField: "OpenAI-Organization")
        }

        let response = try await httpClient.send(request)
        if let error = ProviderError.from(response: response) {
            throw error
        }
        return response
    }

    private func decode<Value: Decodable>(_ response: HTTPResponse) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: response.data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    private func commonQueryItems(for period: ReportingPeriod) -> [URLQueryItem] {
        [
            URLQueryItem(name: "start_time", value: String(Int(period.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(period.end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
    }

    private func reportingPeriod(endingAt now: Date) throws -> ReportingPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startOfToday = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -29, to: startOfToday) else {
            throw ProviderError.invalidResponse
        }
        return try ReportingPeriod(start: start, end: now)
    }
}

private struct OpenAIUsagePage: Decodable {
    let data: [OpenAIUsageBucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAIUsageBucket: Decodable {
    let startTime: Int
    let results: [OpenAIUsageResult]

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case results
    }
}

private struct OpenAIUsageResult: Decodable {
    let inputTokens: Int
    let inputCachedTokens: Int
    let outputTokens: Int
    let requestCount: Int?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case outputTokens = "output_tokens"
        case requestCount = "num_model_requests"
        case model
    }
}

private struct OpenAIRequestCountAggregate {
    private(set) var total = 0
    private(set) var isComplete = true

    mutating func add(_ count: Int?) throws {
        guard let count else {
            isComplete = false
            return
        }
        total = try checkedProviderSum([total, count])
    }

    var value: Int? {
        isComplete ? total : nil
    }
}

private struct OpenAICostPage: Decodable {
    let data: [OpenAICostBucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAICostBucket: Decodable {
    let startTime: Int
    let results: [OpenAICostResult]

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case results
    }
}

private struct OpenAICostResult: Decodable {
    let amount: OpenAICostAmount
}

private struct OpenAICostAmount: Decodable {
    let value: FlexibleDouble
    let currency: String
}

private extension String {
    var nilIfBlank: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
