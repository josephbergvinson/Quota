import QuotaCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 300)
        } detail: {
            detail
        }
        .sheet(isPresented: $model.isShowingAddAccount) {
            AccountEditorView(mode: .add)
                .environmentObject(model)
        }
        .sheet(item: $model.editingAccount) { account in
            AccountEditorView(mode: .edit(account))
                .environmentObject(model)
        }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewDashboardView()
        case .resetPlanner:
            ResetPlannerView()
        case let .account(accountID):
            if let account = model.account(withID: accountID) {
                AccountDetailView(account: account)
            } else {
                ContentUnavailableView(
                    "Account not found",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            }
        }
    }
}
