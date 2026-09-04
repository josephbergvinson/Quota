import Foundation

public struct PersistentState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var accounts: [ConnectedAccount]
    public var snapshots: [UsageSnapshot]

    public init(
        schemaVersion: Int = PersistentState.currentSchemaVersion,
        accounts: [ConnectedAccount] = [],
        snapshots: [UsageSnapshot] = []
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.snapshots = snapshots
    }

    public var latestSnapshotsByAccount: [UUID: UsageSnapshot] {
        Dictionary(
            grouping: snapshots,
            by: \.accountID
        ).compactMapValues { accountSnapshots in
            accountSnapshots.max { $0.capturedAt < $1.capturedAt }
        }
    }

    public func snapshots(for accountID: UUID) -> [UsageSnapshot] {
        snapshots
            .filter { $0.accountID == accountID }
            .sorted { $0.capturedAt < $1.capturedAt }
    }
}
