import Foundation
@testable import QuotaCore

final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> HTTPResponse

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try handler(request)
    }
}

struct NoopCredentialStore: CredentialStoring {
    func save(_ credential: ProviderCredential, for accountID: UUID) throws {}
    func credential(for accountID: UUID) throws -> ProviderCredential? { nil }
    func deleteCredential(for accountID: UUID) throws {}
}

func makeAccount(
    id: UUID = UUID(),
    name: String = "Test Account",
    kind: AccountKind
) throws -> ConnectedAccount {
    try ConnectedAccount(id: id, displayName: name, kind: kind)
}

func makeManualSnapshot(
    accountID: UUID,
    capturedAt: Date,
    usedPercent: Double,
    resetAt: Date?
) throws -> UsageSnapshot {
    let allowance = try Allowance(used: usedPercent, limit: 100, unit: .percent)
    let window = try QuotaWindow(
        identifier: "primary",
        name: "Primary",
        usedPercent: usedPercent,
        resetsAt: resetAt,
        durationMinutes: 300
    )
    return UsageSnapshot.manual(
        accountID: accountID,
        allowance: allowance,
        quotaWindows: [window],
        resetAt: resetAt,
        capturedAt: capturedAt
    )
}
