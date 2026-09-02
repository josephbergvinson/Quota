import QuotaCore
import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject private var model: AppModel
    let account: ConnectedAccount
    @State private var isConfirmingRemoval = false

    private var snapshot: UsageSnapshot? {
        model.latestSnapshots[account.id]
    }

    private var capacity: AccountCapacity {
        UsageAnalytics.capacity(for: account, snapshot: snapshot, now: model.now)
    }

    private var supportedQuotaWindows: [QuotaWindow] {
        guard let snapshot else { return [] }
        return UsageAnalytics.supportedQuotaWindows(for: snapshot)
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
                if account.kind == .chatGPTPro {
                    chatGPTToolbarContent
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

        if let warning = model.chatGPTIdentityWarnings[account.id] {
            Label(warning, systemImage: "person.2.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }

        if account.kind == .chatGPTPro {
            switch model.chatGPTConnectionStates[account.id] ?? .idle {
            case .starting:
                Label("Starting secure ChatGPT sign-in…", systemImage: "person.badge.key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .waitingInBrowser:
                Label("Finish signing in in your browser. Quota is waiting for OpenAI to complete the connection.", systemImage: "safari")
                    .font(.callout)
                    .foregroundStyle(.blue)
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
                let windows = supportedQuotaWindows
                ForEach(windows) { window in
                    QuotaWindowRow(window: window)
                    if window.id != windows.last?.id {
                        Divider()
                    }
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
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
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
                        title: "Cost",
                        value: costUSD.formatted(
                            .currency(code: "USD").precision(.fractionLength(0...2))
                        ),
                        detail: reportingPeriodDescription,
                        symbol: "dollarsign.circle"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let dailyUsage = snapshot?.dailyUsage.value, !dailyUsage.isEmpty {
            UsageHistoryChart(points: dailyUsage, tint: account.kind.provider.tintColor)
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
        case .chatGPTPro:
            "ChatGPT via local Codex service"
        case .openAIAPI:
            "Official admin API"
        }
    }

    private var removalMessage: String {
        switch account.kind {
        case .chatGPTPro:
            "This permanently removes local history and asks Codex to delete its Keychain session."
        case .openAIAPI:
            "This permanently removes local history and the account's Admin API key from macOS Keychain."
        }
    }

    private var providerIdentityDescription: String? {
        model.providerIdentityDescription(for: account.id)
    }

    @ViewBuilder
    private var chatGPTToolbarContent: some View {
        let state = model.chatGPTConnectionStates[account.id] ?? .idle
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
}

private struct QuotaWindowRow: View {
    let window: QuotaWindow

    private var capacityStatus: CapacityStatus {
        .freshStatus(forRemainingPercent: window.remainingPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))% left")
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
