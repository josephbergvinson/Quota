import Foundation

public struct ChatGPTUsageProvider: UsageProvider {
    private static let uninitializedResetTolerance: TimeInterval = 5

    public let dataSourceKind: UsageDataSourceKind = .chatGPTAppServer
    public let accountsDirectoryURL: URL

    public init(accountsDirectoryURL: URL) {
        self.accountsDirectoryURL = accountsDirectoryURL
    }

    public func fetchUsage(
        for account: ConnectedAccount,
        credential: ProviderCredential?,
        now: Date
    ) async throws -> ProviderFetchResult {
        guard account.kind == .chatGPTPro else {
            throw ProviderError.unsupportedAccount
        }

        let connector = try connector(for: account.id)
        let telemetry = try await connector.readTelemetry(capturedAt: now)
        guard
            let providerAccount = telemetry.account.account,
            case let .chatGPT(email, planType) = providerAccount
        else {
            throw ProviderError.invalidResponse
        }
        let quotaWindows = try makeQuotaWindows(
            from: telemetry.rateLimits,
            capturedAt: telemetry.capturedAt
        )
        let bankedResetCredits = try makeBankedResetCredits(
            from: telemetry.rateLimits.resetCredits
        )

        let quotaMetric: Metric<[QuotaWindow]> = quotaWindows.isEmpty
            ? .unavailable(
                UnavailableMetric(
                    reason: .notReturned,
                    detail: "Codex did not return any active rate-limit windows for this account."
                )
            )
            : .available(quotaWindows)
        let resetMetric: Metric<Date>
        if let nextReset = quotaWindows.compactMap(\.resetsAt).filter({ $0 > now }).min() {
            resetMetric = .available(nextReset)
        } else {
            resetMetric = .unavailable(
                UnavailableMetric(
                    reason: .notReturned,
                    detail: "Codex did not return a future reset time."
                )
            )
        }

        let dailyUsage = try (telemetry.tokenUsage.dailyUsage ?? []).map { bucket in
            DailyUsagePoint(
                date: bucket.date,
                unattributedTokens: try checkedInt(bucket.tokens)
            )
        }
        let tokenTotal: Int?
        if telemetry.tokenUsage.dailyUsage != nil {
            tokenTotal = try checkedSum(dailyUsage.map(\.totalTokens))
        } else {
            tokenTotal = nil
        }

        let reportingPeriod: ReportingPeriod?
        if let firstDay = dailyUsage.map(\.date).min(), now > firstDay {
            reportingPeriod = try? ReportingPeriod(start: firstDay, end: now)
        } else {
            reportingPeriod = nil
        }

        let splitTokenUnavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Codex reports aggregate account token activity, not an account-wide input/output split."
        )
        let allowanceUnavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Codex reports percentage-based windows, not an absolute message allowance."
        )
        let unsupportedMetric = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "This metric is not returned for account-wide ChatGPT-backed Codex usage."
        )

        return ProviderFetchResult(
            snapshot: UsageSnapshot(
                accountID: account.id,
                capturedAt: now,
                source: .chatGPTAppServer,
                reportingPeriod: reportingPeriod,
                allowance: .unavailable(allowanceUnavailable),
                quotaWindows: quotaMetric,
                resetAt: resetMetric,
                bankedResetCredits: bankedResetCredits,
                totalTokens: tokenTotal.map(Metric.available)
                    ?? .unavailable(
                        UnavailableMetric(
                            reason: .notReturned,
                            detail: "Codex did not return account token activity."
                        )
                    ),
                inputTokens: .unavailable(splitTokenUnavailable),
                cachedInputTokens: .unavailable(splitTokenUnavailable),
                outputTokens: .unavailable(splitTokenUnavailable),
                requests: .unavailable(unsupportedMetric),
                costUSD: .unavailable(unsupportedMetric),
                modelUsage: .unavailable(
                    UnavailableMetric(
                        reason: .notExposedByProvider,
                        detail: "Codex does not expose model-by-model usage for the whole account."
                    )
                ),
                dailyUsage: telemetry.tokenUsage.dailyUsage == nil
                    ? .unavailable(
                        UnavailableMetric(
                            reason: .notReturned,
                            detail: "Codex did not return daily token buckets."
                        )
                    )
                    : .available(dailyUsage)
            ),
            providerAccountLabel: email,
            providerPlanLabel: humanReadablePlan(planType)
        )
    }

    public func connector(for accountID: UUID) throws -> ChatGPTAppServerConnector {
        let homeURL = codexHomeURL(for: accountID)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try ChatGPTAppServerConnector(codexHomeURL: homeURL)
    }

    public func codexHomeURL(for accountID: UUID) -> URL {
        accountsDirectoryURL
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
    }

    func makeQuotaWindows(
        from limits: ChatGPTRateLimitsDTO,
        capturedAt: Date
    ) throws -> [QuotaWindow] {
        let buckets: [(String, ChatGPTRateLimitSnapshotDTO)]
        if let byID = limits.rateLimitsByLimitID, !byID.isEmpty {
            buckets = byID.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        } else {
            let fallbackID = limits.rateLimits.limitID ?? "default"
            buckets = [(fallbackID, limits.rateLimits)]
        }

        var windows: [QuotaWindow] = []
        for (dictionaryID, bucket) in buckets {
            let limitID = bucket.limitID ?? dictionaryID
            let limitName = bucket.limitName ?? bucket.limitID ?? dictionaryID
            if let primary = bucket.primary,
               isSupportedQuotaWindow(
                   primary,
                   dictionaryID: dictionaryID,
                   limitID: limitID,
                   limitName: limitName
               ),
               !isClearlyUninitialized(primary, capturedAt: capturedAt) {
                windows.append(
                    try makeQuotaWindow(
                        value: primary,
                        identifier: "\(limitID):primary",
                        limitName: limitName,
                        fallbackRole: "Primary"
                    )
                )
            }
            if let secondary = bucket.secondary,
               isSupportedQuotaWindow(
                   secondary,
                   dictionaryID: dictionaryID,
                   limitID: limitID,
                   limitName: limitName
               ),
               !isClearlyUninitialized(secondary, capturedAt: capturedAt) {
                windows.append(
                    try makeQuotaWindow(
                        value: secondary,
                        identifier: "\(limitID):secondary",
                        limitName: limitName,
                        fallbackRole: "Secondary"
                    )
                )
            }
        }
        return windows.sorted {
            if $0.resetsAt == $1.resetsAt { return $0.name < $1.name }
            return ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture)
        }
    }

    func makeBankedResetCredits(
        from resetCredits: ChatGPTRateLimitResetCreditsDTO?
    ) throws -> Metric<BankedResetCredits> {
        guard let resetCredits else {
            return .unavailable(
                UnavailableMetric(
                    reason: .notReturned,
                    detail: "Codex did not return banked reset information for this account."
                )
            )
        }

        let credits = try resetCredits.credits?.map { credit in
            try BankedResetCredit(
                status: bankedResetStatus(credit.status),
                expiresAt: credit.expiresAt
            )
        }
        return .available(
            try BankedResetCredits(
                availableCount: checkedInt(resetCredits.availableCount),
                credits: credits
            )
        )
    }

    private func isSupportedQuotaWindow(
        _ value: ChatGPTRateLimitWindowDTO,
        dictionaryID: String,
        limitID: String,
        limitName: String
    ) -> Bool {
        ChatGPTQuotaWindowPolicy.isSupportedWindow(
            identifier: dictionaryID,
            name: limitName,
            durationMinutes: value.windowDurationMinutes
        ) || ChatGPTQuotaWindowPolicy.isSupportedWindow(
            identifier: limitID,
            name: limitName,
            durationMinutes: value.windowDurationMinutes
        )
    }

    /// Codex can return an unused bucket with a reset anchored to the instant it was read. Such a
    /// reset slides forward on every refresh and does not represent a scheduled provider reset.
    private func isClearlyUninitialized(
        _ value: ChatGPTRateLimitWindowDTO,
        capturedAt: Date
    ) -> Bool {
        guard
            value.usedPercent == 0,
            let durationMinutes = value.windowDurationMinutes,
            durationMinutes > 0,
            let resetsAt = value.resetsAt
        else {
            return false
        }

        let durationSeconds = Double(durationMinutes) * 60
        let resetOffset = resetsAt.timeIntervalSince(capturedAt)
        guard durationSeconds.isFinite, resetOffset.isFinite else { return false }
        return abs(resetOffset - durationSeconds) <= Self.uninitializedResetTolerance
    }

    private func makeQuotaWindow(
        value: ChatGPTRateLimitWindowDTO,
        identifier: String,
        limitName: String,
        fallbackRole: String
    ) throws -> QuotaWindow {
        guard (0...100).contains(value.usedPercent) else {
            throw ProviderError.invalidResponse
        }
        let duration = try value.windowDurationMinutes.map(checkedInt)
        let role = duration.map(durationLabel) ?? fallbackRole
        return try QuotaWindow(
            identifier: identifier,
            name: "\(limitName) · \(role)",
            usedPercent: Double(value.usedPercent),
            resetsAt: value.resetsAt,
            durationMinutes: duration
        )
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes.isMultiple(of: 10_080) {
            return "\(minutes / 10_080)-week"
        }
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)-day"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)-hour"
        }
        return "\(minutes)-minute"
    }

    private func humanReadablePlan(_ planType: String) -> String {
        planType
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .localizedCapitalized
    }

    private func bankedResetStatus(_ status: String) -> BankedResetCreditStatus {
        BankedResetCreditStatus(rawValue: status.lowercased()) ?? .unknown
    }

    private func checkedInt(_ value: Int64) throws -> Int {
        guard let converted = Int(exactly: value), converted >= 0 else {
            throw ProviderError.invalidResponse
        }
        return converted
    }

    private func checkedSum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw ProviderError.invalidResponse }
            return sum
        }
    }
}
