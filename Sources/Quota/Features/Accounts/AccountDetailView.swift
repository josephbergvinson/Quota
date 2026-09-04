import QuotaCore
import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject private var model: AppModel
    let account: ConnectedAccount
    @State private var isConfirmingRemoval = false
    @State private var isShowingModelSpecificLimits = false
    @State private var isShowingClaudeCodeFallback = false
    @State private var claudeAuthorizationCode = ""
    @State private var isSubmittingClaudeCode = false

    private var snapshot: UsageSnapshot? {
        model.latestSnapshots[account.id]
    }

    private var capacity: AccountCapacity {
        UsageAnalytics.capacity(for: account, snapshot: snapshot, now: model.now)
    }

    private var supportedQuotaWindows: [QuotaWindow] {
        guard let snapshot else { return [] }
        return UsageAnalytics.supportedQuotaWindows(
            for: snapshot,
            accountKind: account.kind
        ).filter { window in
            window.resetsAt.map { $0 > model.now } ?? true
        }
    }

    private var planQuotaWindows: [QuotaWindow] {
        supportedQuotaWindows.filter { !isClaudeModelSpecificWindow($0) }
    }

    private var modelSpecificQuotaWindows: [QuotaWindow] {
        supportedQuotaWindows.filter(isClaudeModelSpecificWindow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                accountHeader
                refreshFeedback
                capacitySection
                metricGrid
                historySection
                modelBreakdown
            }
            .padding(24)
        }
        .navigationTitle(account.displayName)
        .toolbar {
            ToolbarItemGroup {
                if account.kind.isChatGPTSubscription {
                    chatGPTToolbarContent
                } else if account.kind.isClaudeSubscription {
                    claudeToolbarContent
                } else {
                    Button {
                        Task { await model.refresh(accountID: account.id) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.refreshStates[account.id] == .refreshing)
                }

                Menu {
                    Button("Edit Account…") {
                        model.editingAccount = account
                    }
                    Divider()
                    Button("Remove Account…", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                } label: {
                    Label("Account Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Remove \(account.displayName)?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove Account", role: .destructive) {
                Task { await model.removeAccount(account) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 14) {
            ProviderIcon(provider: account.kind.provider, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(.largeTitle.weight(.semibold))
                HStack(spacing: 6) {
                    Text(account.kind.displayName)
                    Text("·")
                    Text(connectionSourceLabel)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let providerIdentityDescription {
                    Label(providerIdentityDescription, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if model.refreshStates[account.id] == .refreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var refreshFeedback: some View {
        if let warning = model.refreshWarnings[account.id] {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }

        if let warning = model.identityWarnings[account.id] {
            Label(warning, systemImage: "person.2.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }

        if account.kind.isManagedSubscription {
            switch model.connectionStates[account.id] ?? .idle {
            case .starting:
                Label("Starting secure \(managedProviderName) sign-in…", systemImage: "person.badge.key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .waitingInBrowser:
                VStack(alignment: .leading, spacing: 10) {
                    Label(managedBrowserMessage, systemImage: "safari")
                        .font(.callout)
                        .foregroundStyle(.blue)
                    if account.kind.isClaudeSubscription {
                        DisclosureGroup(
                            "Browser finished, but Quota is still waiting?",
                            isExpanded: $isShowingClaudeCodeFallback
                        ) {
                            claudeCodeFallbackControls
                                .padding(.top, 8)
                        }
                        .font(.caption)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            case let .failed(message):
                Label(message, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .idle, .connected:
                EmptyView()
            }
        }

        if case let .failed(message) = model.refreshStates[account.id] {
            Label(refreshFailureDescription(message), systemImage: "xmark.circle")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func refreshFailureDescription(_ message: String) -> String {
        guard let capturedAt = snapshot?.capturedAt else { return message }
        let timestamp = capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(message) The figures below are from the last successful refresh at \(timestamp)."
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Capacity")
                    .font(.headline)
                Spacer()
                if let capturedAt = capacity.capturedAt {
                    Text("Updated \(capturedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !supportedQuotaWindows.isEmpty {
                quotaWindowRows(planQuotaWindows)

                if !modelSpecificQuotaWindows.isEmpty {
                    if !planQuotaWindows.isEmpty {
                        Divider()
                    }
                    DisclosureGroup(isExpanded: $isShowingModelSpecificLimits) {
                        VStack(alignment: .leading, spacing: 12) {
                            quotaWindowRows(modelSpecificQuotaWindows)
                        }
                        .padding(.top, 10)
                    } label: {
                        HStack {
                            Text("Model-specific limits")
                                .font(.callout.weight(.semibold))
                            Text("\(modelSpecificQuotaWindows.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let allowance = snapshot?.allowance.value {
                    Divider()
                    AdditionalAllowanceRow(
                        allowance: allowance,
                        isStale: capacity.isStale || didRefreshFail,
                        title: account.kind.isClaudeSubscription
                            ? "Usage credits"
                            : "Additional allowance",
                        detail: account.kind.isClaudeSubscription
                            ? "Optional paid usage"
                            : nil
                    )
                }
            } else {
                CapacityBar(capacity: capacity)

                if let allowance = snapshot?.allowance.value {
                    HStack {
                        Text("\(QuotaFormat.amount(allowance.used, unit: allowance.unit)) used")
                        Spacer()
                        Text("\(QuotaFormat.amount(allowance.limit, unit: allowance.unit)) limit")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    UnavailableValue(
                        title: "Remaining allowance unavailable",
                        detail: snapshot?.allowance.unavailability?.detail
                            ?? "Refresh this account. The provider may not report a remaining allowance."
                    )
                }
            }

            if let bankedResetCredits = snapshot?.bankedResetCredits.value {
                Divider()
                BankedResetCreditsView(
                    credits: bankedResetCredits,
                    now: model.now,
                    isFreshReading: !capacity.isStale && !didRefreshFail
                )
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func quotaWindowRows(_ windows: [QuotaWindow]) -> some View {
        ForEach(windows) { window in
            QuotaWindowRow(
                window: window,
                isStale: capacity.isStale || didRefreshFail
            )
            if window.id != windows.last?.id {
                Divider()
            }
        }
    }

    private func isClaudeModelSpecificWindow(_ window: QuotaWindow) -> Bool {
        guard account.kind.isClaudeSubscription else { return false }
        return window.identifier.hasPrefix("model_scoped:")
            || window.identifier == "seven_day_opus"
            || window.identifier == "seven_day_sonnet"
    }

    @ViewBuilder
    private var metricGrid: some View {
        if hasReportedMetrics {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 165), spacing: 12)],
                spacing: 12
            ) {
                if let totalTokens = snapshot?.totalTokens.value {
                    MetricCard(
                        title: "Reported tokens",
                        value: QuotaFormat.compactNumber(totalTokens),
                        detail: reportingPeriodDescription,
                        symbol: "text.word.spacing"
                    )
                }
                if let inputTokens = snapshot?.inputTokens.value {
                    MetricCard(
                        title: "Input tokens",
                        value: QuotaFormat.compactNumber(inputTokens),
                        detail: reportingPeriodDescription,
                        symbol: "arrow.down.forward"
                    )
                }
                if let outputTokens = snapshot?.outputTokens.value {
                    MetricCard(
                        title: "Output tokens",
                        value: QuotaFormat.compactNumber(outputTokens),
                        detail: reportingPeriodDescription,
                        symbol: "arrow.up.forward"
                    )
                }
                if let requests = snapshot?.requests.value {
                    MetricCard(
                        title: "Requests",
                        value: QuotaFormat.compactNumber(requests),
                        detail: reportingPeriodDescription,
                        symbol: "arrow.left.arrow.right"
                    )
                }
                if let costUSD = snapshot?.costUSD.value {
                    MetricCard(
                        title: "Reported cost",
                        value: costUSD.formatted(
                            .currency(code: "USD").precision(.fractionLength(0...2))
                        ),
                        detail: account.kind == .anthropicAPI
                            ? "\(reportingPeriodDescription) · excludes Priority Tier"
                            : reportingPeriodDescription,
                        symbol: "dollarsign.circle"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let dailyUsage = snapshot?.dailyUsage.value, !dailyUsage.isEmpty {
            UsageHistoryChart(
                points: dailyUsage,
                tint: account.kind.provider.tintColor,
                costIsComplete: snapshot?.costUSD.value != nil,
                costQualification: account.kind == .anthropicAPI
                    ? "excludes Priority Tier"
                    : nil
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage over time")
                        .font(.headline)
                    Text("Provider-reported daily total tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ContentUnavailableView(
                    "No token history reported for this account",
                    systemImage: "chart.xyaxis.line"
                )
                .frame(height: 180)
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var modelBreakdown: some View {
        if let models = snapshot?.modelUsage.value, !models.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Usage by model")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        Text("Model")
                        Text("Input")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Cached")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Output")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Divider()
                        .gridCellColumns(4)

                    ForEach(models) { usage in
                        GridRow {
                            Text(usage.model)
                                .lineLimit(1)
                                .help(usage.model)
                            Text(QuotaFormat.compactNumber(usage.inputTokens))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(QuotaFormat.compactNumber(usage.cachedInputTokens))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(QuotaFormat.compactNumber(usage.outputTokens))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
    }

    private var reportingPeriodDescription: String {
        guard let period = snapshot?.reportingPeriod else { return "Latest reading" }
        return "\(period.start.formatted(date: .abbreviated, time: .omitted))–\(period.end.formatted(date: .abbreviated, time: .omitted))"
    }

    private var hasReportedMetrics: Bool {
        snapshot?.totalTokens.value != nil
            || snapshot?.inputTokens.value != nil
            || snapshot?.outputTokens.value != nil
            || snapshot?.requests.value != nil
            || snapshot?.costUSD.value != nil
    }

    private var connectionSourceLabel: String {
        switch account.kind {
        case .chatGPTPlus, .chatGPTPro, .chatGPTSubscription:
            "ChatGPT via local Codex service"
        case .claudePro, .claudeMax, .claudeSubscription:
            "Claude via local Claude Code"
        case .openAIAPI:
            "Official OpenAI Admin API"
        case .anthropicAPI:
            "Official Anthropic Admin API"
        }
    }

    private var removalMessage: String {
        switch account.kind {
        case .chatGPTPlus, .chatGPTPro, .chatGPTSubscription:
            "Quota first asks Codex to sign out and deletes this isolated profile. It removes local history only after that cleanup succeeds, and it does not cancel your ChatGPT subscription."
        case .claudePro, .claudeMax, .claudeSubscription:
            "Quota first signs this isolated Claude Code profile out and deletes it. It removes local history only after that cleanup succeeds, and it does not cancel your Claude subscription or affect other profiles."
        case .openAIAPI, .anthropicAPI:
            "Quota first deletes this account's Admin API key from macOS Keychain, then removes its local history. If cleanup fails, the account stays so you can try again."
        }
    }

    private var providerIdentityDescription: String? {
        model.providerIdentityDescription(for: account.id)
    }

    @ViewBuilder
    private var chatGPTToolbarContent: some View {
        let state = model.connectionStates[account.id] ?? .idle
        if state.isInProgress {
            Button {
                Task { await model.cancelChatGPTLogin(accountID: account.id) }
            } label: {
                Label("Cancel Sign-in", systemImage: "xmark.circle")
            }
        } else {
            Button {
                Task { await model.connectChatGPT(accountID: account.id) }
            } label: {
                Label(
                    model.latestSnapshots[account.id] == nil ? "Connect ChatGPT" : "Reconnect ChatGPT",
                    systemImage: "person.badge.key"
                )
            }
            .disabled(model.refreshStates[account.id] == .refreshing)

            if model.latestSnapshots[account.id] != nil {
                Button {
                    Task { await model.refresh(accountID: account.id) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.refreshStates[account.id] == .refreshing)
            }
        }
    }

    @ViewBuilder
    private var claudeToolbarContent: some View {
        let state = model.connectionStates[account.id] ?? .idle
        if state.isInProgress {
            Button {
                Task { await model.cancelClaudeLogin(accountID: account.id) }
            } label: {
                Label("Cancel Sign-in", systemImage: "xmark.circle")
            }
        } else {
            let isConnected = state == .connected
            Button {
                Task { await model.connectClaude(accountID: account.id) }
            } label: {
                Label(
                    isConnected || model.latestSnapshots[account.id] != nil
                        ? "Reconnect Claude"
                        : "Connect Claude",
                    systemImage: "person.badge.key"
                )
            }
            .disabled(model.refreshStates[account.id] == .refreshing)

            if isConnected || model.latestSnapshots[account.id] != nil {
                Button {
                    Task { await model.refresh(accountID: account.id) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.refreshStates[account.id] == .refreshing)
            }
        }
    }

    private var managedProviderName: String {
        account.kind.isClaudeSubscription ? "Claude" : "ChatGPT"
    }

    private var managedBrowserMessage: String {
        if account.kind.isClaudeSubscription {
            return "Finish signing in in your browser. Choose the Claude account you intend to track; Quota is waiting for Claude Code to complete the connection."
        }
        return "Finish signing in in your browser. Quota is waiting for OpenAI to complete the connection."
    }

    private var didRefreshFail: Bool {
        if case .failed = model.refreshStates[account.id] {
            return true
        }
        return false
    }

    private var claudeCodeFallbackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open Claude's code-based sign-in, then paste the complete code shown there. This stays in the current secure sign-in session.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Code-Based Sign-in") {
                    Task { await model.openClaudeCodeFallback(accountID: account.id) }
                }
                SecureField("Claude sign-in code", text: $claudeAuthorizationCode)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .onSubmit { submitClaudeCodeFallback() }
                Button("Complete Sign-in") {
                    submitClaudeCodeFallback()
                }
                .disabled(
                    isSubmittingClaudeCode
                        || claudeAuthorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private func submitClaudeCodeFallback() {
        guard !isSubmittingClaudeCode else { return }
        isSubmittingClaudeCode = true
        let code = claudeAuthorizationCode
        claudeAuthorizationCode = ""
        Task {
            _ = await model.submitClaudeCodeFallback(accountID: account.id, code: code)
            isSubmittingClaudeCode = false
        }
    }
}

private struct AdditionalAllowanceRow: View {
    let allowance: Allowance
    let isStale: Bool
    let title: String
    let detail: String?

    private var status: CapacityStatus {
        isStale ? .stale : .freshStatus(forRemainingFraction: allowance.remainingFraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(
                    isStale
                        ? "\(QuotaFormat.amount(allowance.remaining, unit: allowance.unit)) last reported"
                        : "\(QuotaFormat.amount(allowance.remaining, unit: allowance.unit)) left"
                )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(status.color)
            }
            CapacityProgressIndicator(
                remainingFraction: allowance.remainingFraction,
                status: status
            )
            HStack {
                Text("\(QuotaFormat.amount(allowance.used, unit: allowance.unit)) used of \(QuotaFormat.amount(allowance.limit, unit: allowance.unit))")
                Spacer()
                if let detail {
                    Text(detail)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct BankedResetCreditsView: View {
    let credits: BankedResetCredits
    let now: Date
    let isFreshReading: Bool

    private static let collapsedExpiryGroupLimit = 3

    private var displayedCredits: [BankedResetCredit] {
        let eligibleCredits = (credits.credits ?? []).filter {
            $0.status == .available || $0.status == .unknown
        }
        return Array(
            eligibleCredits
                .sorted { left, right in
                    switch (left.expiresAt, right.expiresAt) {
                    case let (leftDate?, rightDate?):
                        leftDate < rightDate
                    case (_?, nil):
                        true
                    case (nil, _?):
                        false
                    case (nil, nil):
                        false
                    }
                }
                .prefix(credits.availableCount)
        )
    }

    private var expiryGroups: [ExpiryGroup] {
        Dictionary(grouping: displayedCredits, by: \.expiresAt)
            .compactMap { date, groupedCredits in
                guard let date else { return nil }
                return ExpiryGroup(
                    date: date,
                    count: groupedCredits.count,
                    hasUncertainStatus: groupedCredits.contains { $0.status == .unknown }
                )
            }
            .sorted { $0.date < $1.date }
    }

    private var nonExpiringCount: Int {
        displayedCredits.filter { $0.expiresAt == nil }.count
    }

    private var hasUncertainNonExpiringCredit: Bool {
        displayedCredits.contains { $0.expiresAt == nil && $0.status == .unknown }
    }

    private var visibleExpiryGroups: [ExpiryGroup] {
        Array(expiryGroups.prefix(Self.collapsedExpiryGroupLimit))
    }

    private var hiddenExpiryGroups: [ExpiryGroup] {
        Array(expiryGroups.dropFirst(Self.collapsedExpiryGroupLimit))
    }

    private var missingDetailCount: Int {
        max(0, credits.availableCount - displayedCredits.count)
    }

    private var hasPassedReportedExpiry: Bool {
        expiryGroups.contains { $0.date <= now }
    }

    private var usesLastReportedLanguage: Bool {
        !isFreshReading || hasPassedReportedExpiry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Banked resets", systemImage: "arrow.counterclockwise.circle")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(
                    usesLastReportedLanguage
                        ? "Last reported: \(credits.availableCount)"
                        : "\(credits.availableCount) available"
                )
                    .font(.callout.weight(.semibold))
            }

            if credits.availableCount == 0 {
                Text(
                    usesLastReportedLanguage
                        ? "No banked resets were reported in this reading."
                        : "No banked resets available."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleExpiryGroups) { group in
                    expiryRow(group)
                }

                if !hiddenExpiryGroups.isEmpty {
                    DisclosureGroup(
                        hiddenExpiryGroups.count == 1
                            ? "Show 1 more expiry time"
                            : "Show \(hiddenExpiryGroups.count) more expiry times"
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(hiddenExpiryGroups) { group in
                                expiryRow(group)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if nonExpiringCount > 0 {
                    Label(
                        nonExpiringDescription,
                        systemImage: "infinity"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if missingDetailCount > 0 {
                    Label(
                        missingDetailCount == 1
                            ? "Expiry details unavailable for 1 banked reset"
                            : "Expiry details unavailable for \(missingDetailCount) banked resets",
                        systemImage: "questionmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .help("Earned Codex rate-limit resets reported by OpenAI")
    }

    private var nonExpiringDescription: String {
        if usesLastReportedLanguage || hasUncertainNonExpiringCredit {
            return nonExpiringCount == 1
                ? "1 reset was reported as non-expiring"
                : "\(nonExpiringCount) resets were reported as non-expiring"
        }
        return nonExpiringCount == 1
            ? "1 banked reset does not expire"
            : "\(nonExpiringCount) banked resets do not expire"
    }

    private func expiryRow(_ group: ExpiryGroup) -> some View {
        let label = expiryLabel(for: group)
        let formattedDate = group.date.formatted(date: .abbreviated, time: .shortened)
        let isPast = group.date <= now

        return HStack(alignment: .firstTextBaseline) {
            Label(label, systemImage: isPast ? "clock.badge.exclamationmark" : "clock")
            Spacer(minLength: 12)
            Text(formattedDate)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .foregroundStyle(isPast ? Color.orange : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(formattedDate)")
    }

    private func expiryLabel(for group: ExpiryGroup) -> String {
        if group.date <= now {
            return group.count == 1
                ? "1 reported expiry passed"
                : "\(group.count) reported expiries passed"
        }
        if usesLastReportedLanguage || group.hasUncertainStatus {
            return group.count == 1
                ? "1 reported expiry"
                : "\(group.count) reported expiries"
        }
        return group.count == 1
            ? "1 reset expires"
            : "\(group.count) resets expire"
    }

    private struct ExpiryGroup: Identifiable {
        let date: Date
        let count: Int
        let hasUncertainStatus: Bool

        var id: Date { date }
    }
}

private struct QuotaWindowRow: View {
    let window: QuotaWindow
    let isStale: Bool

    private var capacityStatus: CapacityStatus {
        isStale ? .stale : .freshStatus(forRemainingPercent: window.remainingPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(
                    isStale
                        ? "\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))% last reported"
                        : "\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))% left"
                )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(capacityStatus.color)
            }
            CapacityProgressIndicator(
                remainingFraction: window.remainingPercent / 100,
                status: capacityStatus
            )
            HStack {
                Text("\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used")
                Spacer()
                if let reset = window.resetsAt {
                    Label(reset.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                } else {
                    Text("Reset unavailable")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .help(capacityStatus.label)
    }
}
