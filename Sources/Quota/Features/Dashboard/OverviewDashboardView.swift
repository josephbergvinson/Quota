import QuotaCore
import SwiftUI

struct OverviewDashboardView: View {
    private enum DashboardRange: String, CaseIterable, Identifiable {
        case sevenDays
        case thirtyDays
        case all

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sevenDays: "7D"
            case .thirtyDays: "30D"
            case .all: "All"
            }
        }

        var description: String {
            switch self {
            case .sevenDays: "Last 7 days"
            case .thirtyDays: "Last 30 days"
            case .all: "All reported history"
            }
        }

        var dayCount: Int? {
            switch self {
            case .sevenDays: 7
            case .thirtyDays: 30
            case .all: nil
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var selectedRange: DashboardRange = .sevenDays

    var body: some View {
        Group {
            if !model.isLoaded {
                ProgressView("Loading Quota…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.accounts.isEmpty {
                emptyState
            } else {
                dashboard
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("Refresh all connected provider accounts")
            }
        }
    }

    private var dashboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                summaryMetrics
                recommendation

                VStack(alignment: .leading, spacing: 12) {
                    Text("Accounts")
                        .font(.title3.weight(.semibold))
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 270), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(model.dashboardSummary.capacities, id: \.account.id) { capacity in
                            AccountCapacityCard(capacity: capacity)
                        }
                    }
                }

                if !tokenBreakdown.dailyPoints.isEmpty {
                    UsageHistoryChart(points: tokenBreakdown.dailyPoints)
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your AI capacity at a glance")
                    .font(.largeTitle.weight(.semibold))
                Text("Known limits are kept separate from metrics providers do not expose.")
                    .foregroundStyle(.secondary)
                Text("Readings older than six hours are marked stale and excluded from recommendations.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 10) {
                Picker("Analytics range", selection: $selectedRange) {
                    ForEach(DashboardRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .accessibilityLabel("Analytics range")

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var recommendation: some View {
        if let recommendation = model.dashboardSummary.recommendedAccount,
           let remaining = recommendation.remainingFraction {
            Button {
                model.selection = .account(recommendation.account.id)
            } label: {
                HStack(spacing: 14) {
                    ProviderIcon(provider: recommendation.account.kind.provider, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Best recent account to use next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(recommendation.account.displayName)
                                .font(.title3.weight(.semibold))
                            Text("· \(QuotaFormat.percentage(remaining)) left")
                                .foregroundStyle(.secondary)
                        }
                        if let windowName = recommendation.limitingWindowName {
                            Text("Based on the most constrained reported window: \(windowName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let capturedAt = recommendation.capturedAt {
                            Text("Reported \(capturedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                VisualEffectBackground(material: .menu)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(recommendation.account.kind.provider.tintColor.opacity(0.35), lineWidth: 1)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No recent capacity reading")
                        .font(.headline)
                    Text("Refresh a connected account or record a subscription reading to get a recommendation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var summaryMetrics: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
            spacing: 12
        ) {
            MetricCard(
                title: "Total tokens",
                value: tokenBreakdown.totalTokens.map(QuotaFormat.compactNumber) ?? "—",
                detail: totalTokenDetail,
                symbol: "text.word.spacing"
            )

            if hasTokenSplit {
                MetricCard(
                    title: "Uncached input",
                    value: tokenBreakdown.uncachedInputTokens.map(QuotaFormat.compactNumber) ?? "—",
                    detail: uncachedTokenDetail,
                    symbol: "square.dashed"
                )

                MetricCard(
                    title: "Cached input",
                    value: tokenBreakdown.cachedInputTokens.map(QuotaFormat.compactNumber) ?? "—",
                    detail: splitTokenDetail,
                    symbol: "bolt.horizontal.circle"
                )

                MetricCard(
                    title: "Output tokens",
                    value: tokenBreakdown.outputTokens.map(QuotaFormat.compactNumber) ?? "—",
                    detail: splitTokenDetail,
                    symbol: "arrow.up.circle"
                )
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No accounts yet", systemImage: "gauge.with.dots.needle.0percent")
        } description: {
            Text("Add a ChatGPT or OpenAI account to start tracking capacity.")
        } actions: {
            Button("Add Account…") {
                model.isShowingAddAccount = true
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tokenBreakdown: DashboardTokenBreakdown {
        UsageAnalytics.tokenBreakdown(
            accounts: model.accounts,
            snapshots: model.state.snapshots,
            now: model.now,
            dayCount: selectedRange.dayCount
        )
    }

    private var totalTokenDetail: String {
        guard tokenBreakdown.accountsReportingDailyUsage > 0 else {
            return "Daily token history is unavailable from connected providers"
        }
        return "\(selectedRange.description) · \(tokenBreakdown.accountsReportingDailyUsage) of \(tokenBreakdown.accountCount) accounts"
    }

    private var splitTokenDetail: String {
        guard tokenBreakdown.accountsReportingTokenSplit > 0 else {
            return "Unavailable for accounts without provider-reported token splits"
        }
        return "\(selectedRange.description) · \(tokenBreakdown.accountsReportingTokenSplit) of \(tokenBreakdown.accountCount) accounts"
    }

    private var hasTokenSplit: Bool {
        tokenBreakdown.uncachedInputTokens != nil
            || tokenBreakdown.cachedInputTokens != nil
            || tokenBreakdown.outputTokens != nil
    }

    private var uncachedTokenDetail: String {
        guard tokenBreakdown.accountsReportingTokenSplit > 0 else {
            return splitTokenDetail
        }
        return "\(tokenBreakdown.accountsReportingTokenSplit) of \(tokenBreakdown.accountCount) accounts · includes cache writes"
    }
}

private struct AccountCapacityCard: View {
    @EnvironmentObject private var model: AppModel
    let capacity: AccountCapacity

    var body: some View {
        Button {
            model.selection = .account(capacity.account.id)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ProviderIcon(provider: capacity.account.kind.provider, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(capacity.account.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(capacity.account.kind.shortName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                CapacityBar(capacity: capacity)

                if let bankedResetCredits, bankedResetCredits.availableCount > 0 {
                    Label(
                        bankedResetDescription(bankedResetCredits),
                        systemImage: bankedResetHasPassedExpiry(bankedResetCredits)
                            ? "clock.badge.exclamationmark"
                            : "arrow.counterclockwise.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        bankedResetHasPassedExpiry(bankedResetCredits)
                            ? Color.orange
                            : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if let reset = capacity.nextResetAt {
                        Label(
                            "Next reset \(reset.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "clock"
                        )
                    } else {
                        Label("Reset unavailable", systemImage: "clock.badge.questionmark")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let capturedAt = capacity.capturedAt {
                    Label(
                        capacity.isStale
                            ? "Reading is stale · updated \(capturedAt.formatted(.relative(presentation: .named)))"
                            : "Updated \(capturedAt.formatted(.relative(presentation: .named)))",
                        systemImage: capacity.isStale ? "clock.badge.exclamationmark" : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(capacity.isStale ? Color.orange : Color.secondary)
                }

                if case .failed = model.refreshStates[capacity.account.id] {
                    Label("Refresh failed · showing the last saved reading", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var bankedResetCredits: BankedResetCredits? {
        model.latestSnapshots[capacity.account.id]?.bankedResetCredits.value
    }

    private var didRefreshFail: Bool {
        if case .failed = model.refreshStates[capacity.account.id] {
            return true
        }
        return false
    }

    private func reportedExpiryCredits(_ credits: BankedResetCredits) -> [BankedResetCredit] {
        (credits.credits ?? [])
            .filter {
                ($0.status == .available || $0.status == .unknown)
                    && $0.expiresAt != nil
            }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    private func bankedResetHasPassedExpiry(_ credits: BankedResetCredits) -> Bool {
        reportedExpiryCredits(credits).contains { ($0.expiresAt ?? .distantFuture) <= model.now }
    }

    private func bankedResetDescription(_ credits: BankedResetCredits) -> String {
        let countDescription = credits.availableCount == 1
            ? "1 banked reset"
            : "\(credits.availableCount) banked resets"
        let usesLastReportedLanguage = capacity.isStale
            || didRefreshFail
            || bankedResetHasPassedExpiry(credits)
        let availabilityDescription = usesLastReportedLanguage
            ? "Last reported: \(countDescription)"
            : countDescription

        guard
            let earliestCredit = reportedExpiryCredits(credits).first,
            let earliestExpiry = earliestCredit.expiresAt
        else {
            return availabilityDescription
        }

        let formattedExpiry = earliestExpiry.formatted(date: .abbreviated, time: .shortened)
        if earliestExpiry <= model.now {
            return "\(availabilityDescription) · reported expiry passed \(formattedExpiry)"
        }
        let expiryLabel = usesLastReportedLanguage || earliestCredit.status == .unknown
            ? "reported expiry"
            : "earliest expiry"
        return "\(availabilityDescription) · \(expiryLabel) \(formattedExpiry)"
    }
}
