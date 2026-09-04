import QuotaCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section {
                Label("Overview", systemImage: "rectangle.grid.2x2")
                    .tag(AppRoute.overview)
                Label("Reset Planner", systemImage: "calendar.badge.clock")
                    .tag(AppRoute.resetPlanner)
            }

            ForEach(ProviderKind.allCases) { provider in
                let providerAccounts = model.accounts.filter { $0.kind.provider == provider }
                if !providerAccounts.isEmpty {
                    Section(provider.displayName) {
                        ForEach(providerAccounts) { account in
                            AccountSidebarRow(account: account)
                                .tag(AppRoute.account(account.id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Quota")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.isShowingAddAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)

                Spacer()

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing accounts")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct AccountSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let account: ConnectedAccount

    var body: some View {
        HStack(spacing: 9) {
            ProviderIcon(provider: account.kind.provider, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .lineLimit(1)
                Text(account.kind.shortName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            statusIndicator
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if model.connectionStates[account.id]?.isInProgress == true {
            ProgressView()
                .controlSize(.mini)
                .help("Waiting for sign-in")
                .accessibilityLabel("Waiting for account sign-in")
        } else {
            switch model.refreshStates[account.id] ?? .idle {
            case .refreshing:
                ProgressView()
                    .controlSize(.mini)
                    .help("Refreshing")
                    .accessibilityLabel("Refreshing account usage")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Refresh failed")
                    .accessibilityLabel("Refresh failed")
            default:
                let capacity = UsageAnalytics.capacity(
                    for: account,
                    snapshot: model.latestSnapshots[account.id],
                    now: model.now
                )
                let status = capacity.status
                Image(systemName: status.indicatorSymbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(status.color)
                    .frame(width: 12, height: 12)
                    .help(status.label)
                    .accessibilityLabel(status.label)
            }
        }
    }
}
