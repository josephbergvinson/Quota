import Foundation

public struct ManagedAccountIdentityAssessment: Equatable, Sendable {
    public let unverifiedAccountIDs: Set<UUID>
    public let duplicateAccountIDsByAccount: [UUID: Set<UUID>]

    public init(
        unverifiedAccountIDs: Set<UUID>,
        duplicateAccountIDsByAccount: [UUID: Set<UUID>]
    ) {
        self.unverifiedAccountIDs = unverifiedAccountIDs
        self.duplicateAccountIDsByAccount = duplicateAccountIDsByAccount
    }

    public var ineligibleAccountIDs: Set<UUID> {
        unverifiedAccountIDs.union(duplicateAccountIDsByAccount.keys)
    }
}

public extension UsageAnalytics {
    /// Assesses whether managed subscription rows can safely participate in rotation advice.
    /// API organizations are excluded because they do not represent browser-authenticated seats.
    static func managedAccountIdentityAssessment(
        accounts: [ConnectedAccount],
        identityKeys: [UUID: String]
    ) -> ManagedAccountIdentityAssessment {
        let managedAccounts = accounts.filter(\.kind.isManagedSubscription)
        var normalizedKeys: [UUID: String] = [:]
        var unverifiedAccountIDs: Set<UUID> = []

        for account in managedAccounts {
            guard let key = identityKeys[account.id]?.normalizedIdentityKey else {
                unverifiedAccountIDs.insert(account.id)
                continue
            }
            normalizedKeys[account.id] = key
        }

        var duplicateAccountIDsByAccount: [UUID: Set<UUID>] = [:]
        for provider in ProviderKind.allCases {
            let providerAccounts = managedAccounts.filter { $0.kind.provider == provider }
            let groups = Dictionary(grouping: providerAccounts) { account in
                normalizedKeys[account.id]
            }
            for (key, matchingAccounts) in groups where key != nil && matchingAccounts.count > 1 {
                let matchingIDs = Set(matchingAccounts.map(\.id))
                for accountID in matchingIDs {
                    duplicateAccountIDsByAccount[accountID] = matchingIDs.subtracting([accountID])
                }
            }
        }

        return ManagedAccountIdentityAssessment(
            unverifiedAccountIDs: unverifiedAccountIDs,
            duplicateAccountIDsByAccount: duplicateAccountIDsByAccount
        )
    }
}

private extension String {
    var normalizedIdentityKey: String? {
        let components = trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }

        let kind = components[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch kind {
        case "email":
            return "email:\(value.lowercased())"
        case "org":
            if let identifier = UUID(uuidString: value) {
                return "org:\(identifier.uuidString.lowercased())"
            }
            // Opaque provider identifiers are case-sensitive unless their issuer says otherwise.
            return "org:\(value)"
        default:
            return nil
        }
    }
}
