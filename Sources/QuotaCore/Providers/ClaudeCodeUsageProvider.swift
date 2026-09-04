import Foundation

public struct ClaudeCodeUsageProvider: UsageProvider {
    public let dataSourceKind: UsageDataSourceKind = .claudeCodeOAuth
    public let accountsDirectoryURL: URL

    private let connectorFactory: @Sendable (UUID) throws -> any ClaudeCodeConnecting

    public init(accountsDirectoryURL: URL) {
        self.accountsDirectoryURL = canonicalClaudeConfigurationURL(accountsDirectoryURL)
        self.connectorFactory = { accountID in
            try ClaudeCodeConnector(
                configurationDirectoryURL: canonicalClaudeConfigurationURL(accountsDirectoryURL)
                    .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            )
        }
    }

    init(
        accountsDirectoryURL: URL,
        connectorFactory: @escaping @Sendable (UUID) throws -> any ClaudeCodeConnecting
    ) {
        self.accountsDirectoryURL = canonicalClaudeConfigurationURL(accountsDirectoryURL)
        self.connectorFactory = connectorFactory
    }

    public func fetchUsage(
        for account: ConnectedAccount,
        credential: ProviderCredential?,
        now: Date
    ) async throws -> ProviderFetchResult {
        guard account.kind.isClaudeSubscription else {
            throw ProviderError.unsupportedAccount
        }

        let connector = try connectorFactory(account.id)
        let subscriptionUsage = try await connector.readSubscriptionUsage()
        let status = subscriptionUsage.status
        let usage = subscriptionUsage.usage
        let reportedPlan = usage.subscriptionType ?? status.subscriptionType
        if
            let plan = reportedPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
            !plan.isEmpty,
            resolvedClaudeSubscriptionAccountKind(from: plan) == nil
        {
            throw ClaudeCodeConnectorError.unsupportedSubscriptionPlan
        }
        guard usage.rateLimitsAvailable else {
            throw ClaudeCodeConnectorError.usageUnavailable
        }
        let quotaWindows = try makeQuotaWindows(from: usage.rateLimits)
        guard !quotaWindows.isEmpty else {
            throw ClaudeCodeConnectorError.usageUnavailable
        }

        let resetMetric: Metric<Date>
        if let nextReset = quotaWindows.compactMap(\.resetsAt).filter({ $0 > now }).min() {
            resetMetric = .available(nextReset)
        } else {
            resetMetric = .unavailable(
                UnavailableMetric(
                    reason: .notReturned,
                    detail: "Claude Code did not return a future reset time."
                )
            )
        }

        let extraUsageAllowance = try makeExtraUsageAllowance(usage.rateLimits?.extraUsage)
        let noTokenHistory = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Claude does not expose account-wide token history for Pro or Max subscriptions."
        )
        let noRequestHistory = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Claude does not expose account-wide request history for Pro or Max subscriptions."
        )
        let noCostHistory = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Subscription usage is not reported as API cost."
        )
        let noBankedResets = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Claude does not expose banked reset credits for Pro or Max subscriptions."
        )

        return ProviderFetchResult(
            snapshot: UsageSnapshot(
                accountID: account.id,
                capturedAt: now,
                source: .claudeCodeOAuth,
                reportingPeriod: nil,
                allowance: extraUsageAllowance,
                quotaWindows: .available(quotaWindows),
                resetAt: resetMetric,
                bankedResetCredits: .unavailable(noBankedResets),
                totalTokens: .unavailable(noTokenHistory),
                inputTokens: .unavailable(noTokenHistory),
                cachedInputTokens: .unavailable(noTokenHistory),
                outputTokens: .unavailable(noTokenHistory),
                requests: .unavailable(noRequestHistory),
                costUSD: .unavailable(noCostHistory),
                modelUsage: .unavailable(noTokenHistory),
                dailyUsage: .unavailable(noTokenHistory)
            ),
            providerAccountLabel: status.email?.nilIfBlank ?? status.organizationName?.nilIfBlank,
            providerIdentityKey: providerIdentityKey(from: status),
            providerPlanLabel: humanReadablePlan(reportedPlan),
            resolvedAccountKind: resolvedAccountKind(from: reportedPlan)
        )
    }

    public func configurationDirectoryURL(for accountID: UUID) -> URL {
        accountsDirectoryURL
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
    }

    private func providerIdentityKey(from status: ClaudeCodeAuthStatusDTO) -> String? {
        // A single namespace is required for duplicate detection. Falling back to email
        // would let the same seat appear once as `org:` and once as `email:` and evade
        // rotation-safety checks when Claude omits optional metadata from one response.
        status.organizationID?.nilIfBlank.map { "org:\($0)" }
    }

    public func connector(for accountID: UUID) throws -> ClaudeCodeConnector {
        try ClaudeCodeConnector(
            configurationDirectoryURL: configurationDirectoryURL(for: accountID)
        )
    }

    func makeQuotaWindows(from limits: ClaudeCodeRateLimitsDTO?) throws -> [QuotaWindow] {
        guard let limits else { return [] }
        let standardWindows: [(
            identifier: String,
            name: String,
            durationMinutes: Int,
            value: ClaudeCodeRateLimitWindowDTO?
        )] = [
            ("five_hour", "5-hour limit", 300, limits.fiveHour),
            ("seven_day", "7-day limit · all models", 10_080, limits.sevenDay),
            (
                "seven_day_oauth_apps",
                "7-day limit · OAuth apps",
                10_080,
                limits.sevenDayOAuthApps
            )
        ]
        let planWindows = try standardWindows.compactMap { item in
            try makeQuotaWindow(
                identifier: item.identifier,
                name: item.name,
                durationMinutes: item.durationMinutes,
                value: item.value
            )
        }

        var modelScopedLabels = Set<String>()
        var modelWindows: [QuotaWindow] = []
        for scopedWindow in limits.modelScoped.sorted(by: { left, right in
            left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }) {
            let displayName = scopedWindow.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { continue }
            let normalizedLabel = displayName.lowercased()
            guard !modelScopedLabels.contains(normalizedLabel) else { continue }
            let value = ClaudeCodeRateLimitWindowDTO(
                utilization: scopedWindow.utilization,
                resetsAt: scopedWindow.resetsAt
            )
            if let window = try makeQuotaWindow(
                identifier: "model_scoped:\(normalizedLabel)",
                name: "7-day limit · \(displayName)",
                durationMinutes: 10_080,
                value: value
            ) {
                modelScopedLabels.insert(normalizedLabel)
                modelWindows.append(window)
            }
        }

        let legacyModelWindows: [(
            token: String,
            identifier: String,
            name: String,
            value: ClaudeCodeRateLimitWindowDTO?
        )] = [
            ("opus", "seven_day_opus", "7-day limit · Opus", limits.sevenDayOpus),
            ("sonnet", "seven_day_sonnet", "7-day limit · Sonnet", limits.sevenDaySonnet)
        ]
        for item in legacyModelWindows {
            guard !modelScopedLabels.contains(where: { $0.contains(item.token) }) else {
                continue
            }
            if let window = try makeQuotaWindow(
                identifier: item.identifier,
                name: item.name,
                durationMinutes: 10_080,
                value: item.value
            ) {
                modelWindows.append(window)
            }
        }
        modelWindows.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return planWindows + modelWindows
    }

    private func makeQuotaWindow(
        identifier: String,
        name: String,
        durationMinutes: Int,
        value: ClaudeCodeRateLimitWindowDTO?
    ) throws -> QuotaWindow? {
        guard let value, let utilization = value.utilization else {
            return nil
        }
        guard utilization.isFinite, (0...100).contains(utilization) else {
            throw ProviderError.invalidResponse
        }
        let reset = try value.resetsAt.map(parseISO8601Date)
        return try QuotaWindow(
            identifier: identifier,
            name: name,
            usedPercent: utilization,
            resetsAt: reset,
            durationMinutes: durationMinutes
        )
    }

    private func makeExtraUsageAllowance(
        _ extraUsage: ClaudeCodeExtraUsageDTO?
    ) throws -> Metric<Allowance> {
        let unavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Claude Code did not report an enabled usage-credit allowance."
        )
        guard
            let extraUsage,
            extraUsage.isEnabled,
            let usedCredits = extraUsage.usedCredits,
            let monthlyLimit = extraUsage.monthlyLimit
        else {
            return .unavailable(unavailable)
        }
        guard
            usedCredits.isFinite,
            monthlyLimit.isFinite,
            usedCredits >= 0,
            monthlyLimit > 0
        else {
            throw ProviderError.invalidResponse
        }
        let normalizedCurrency = extraUsage.currency?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalizedCurrency == "USD" else {
            return .available(
                try Allowance(used: usedCredits, limit: monthlyLimit, unit: .credits)
            )
        }

        // Claude reports extra-usage money in minor currency units. Older Claude Code
        // responses omit `decimal_places`; USD safely falls back to its exponent of 2.
        let exponent = extraUsage.minorUnitExponent ?? 2
        guard (0...9).contains(exponent) else {
            throw ProviderError.invalidResponse
        }
        let divisor = pow(10, Double(exponent))
        let usedDollars = usedCredits / divisor
        let limitDollars = monthlyLimit / divisor
        guard usedDollars.isFinite, limitDollars.isFinite else {
            throw ProviderError.invalidResponse
        }
        return .available(
            try Allowance(used: usedDollars, limit: limitDollars, unit: .dollars)
        )
    }

    private func parseISO8601Date(_ value: String) throws -> Date {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw ProviderError.invalidResponse
        }
        return date
    }

    private func humanReadablePlan(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else {
            return nil
        }
        return plan
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .localizedCapitalized
    }

    func resolvedAccountKind(from plan: String?) -> AccountKind? {
        resolvedClaudeSubscriptionAccountKind(from: plan)
    }
}

func resolvedClaudeSubscriptionAccountKind(from plan: String?) -> AccountKind? {
    let words = plan?
        .lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init) ?? []
    if words.contains("max") {
        return .claudeMax
    }
    if words.contains("pro") {
        return .claudePro
    }
    return nil
}

private extension String {
    var nilIfBlank: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
