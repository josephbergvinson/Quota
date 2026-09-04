import Foundation

public enum LocalDataStoreError: LocalizedError, Equatable {
    case unsupportedSchema(found: Int, supported: Int)
    case duplicateAccountIdentifier
    case orphanedSnapshot
    case invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(found, supported):
            "The local data uses schema version \(found), but this version of Quota supports version \(supported)."
        case .duplicateAccountIdentifier:
            "The local data contains duplicate account identifiers."
        case .orphanedSnapshot:
            "The local data contains history for an account that no longer exists."
        case .invalidSnapshot:
            "The local data contains an invalid usage snapshot."
        }
    }
}

public actor LocalDataStore {
    public static let stateFileName = "quota-data.json"

    public nonisolated let directoryURL: URL
    private let stateFileURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        let resolvedDirectory = try directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.directoryURL = resolvedDirectory
        self.stateFileURL = resolvedDirectory.appendingPathComponent(Self.stateFileName, isDirectory: false)
        self.fileManager = fileManager
    }

    public func load() throws -> PersistentState {
        guard fileManager.fileExists(atPath: stateFileURL.path) else {
            return PersistentState()
        }

        let storedData = try Data(contentsOf: stateFileURL)
        let migration = try Self.migratingStateIfNeeded(from: storedData)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        let state = try decoder.decode(PersistentState.self, from: migration.data)
        try validate(state)
        if migration.didMigrate {
            try save(state)
        }
        return state
    }

    public func save(_ state: PersistentState) throws {
        try validate(state)
        try ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: stateFileURL, options: .atomic)
    }

    private static func defaultDirectoryURL(fileManager: FileManager) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport.appendingPathComponent("Quota", isDirectory: true)
    }

    private static func migratingStateIfNeeded(from data: Data) throws -> StateMigrationResult {
        guard
            var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schemaVersion = root["schemaVersion"] as? Int
        else {
            return StateMigrationResult(data: data, didMigrate: false)
        }

        guard schemaVersion <= PersistentState.currentSchemaVersion else {
            throw LocalDataStoreError.unsupportedSchema(
                found: schemaVersion,
                supported: PersistentState.currentSchemaVersion
            )
        }
        guard schemaVersion < PersistentState.currentSchemaVersion else {
            return StateMigrationResult(data: data, didMigrate: false)
        }

        // Schema 1 labeled every ChatGPT subscription `chatGPTPro` and called its single Claude
        // choice `claudeMax`, even though neither old label established the actual tier. Preserve
        // that uncertainty until the provider reports an authoritative plan. Retired Anthropic API
        // records are intentionally retained because schema 2 restores that provider.
        guard schemaVersion == 1, var accounts = root["accounts"] as? [[String: Any]] else {
            return StateMigrationResult(data: data, didMigrate: false)
        }
        for index in accounts.indices {
            switch accounts[index]["kind"] as? String {
            case "chatGPTPro":
                accounts[index]["kind"] = "chatGPTSubscription"
            case "claudeMax":
                accounts[index]["kind"] = "claudeSubscription"
            default:
                break
            }
        }
        root["accounts"] = accounts
        if let snapshots = root["snapshots"] as? [[String: Any]] {
            var accountKindsByIdentifier: [String: String] = [:]
            for account in accounts {
                guard
                    let identifier = account["id"] as? String,
                    let kind = account["kind"] as? String
                else {
                    continue
                }
                accountKindsByIdentifier[identifier.lowercased()] = kind
            }
            root["snapshots"] = snapshots.filter { snapshot in
                guard
                    let identifier = (snapshot["accountID"] as? String)?.lowercased(),
                    let kind = accountKindsByIdentifier[identifier],
                    let source = snapshot["source"] as? String
                else {
                    return true
                }
                return Self.isCompatible(snapshotSource: source, accountKind: kind)
            }
        }
        root["schemaVersion"] = PersistentState.currentSchemaVersion
        return StateMigrationResult(
            data: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            didMigrate: true
        )
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func validate(_ state: PersistentState) throws {
        guard state.schemaVersion == PersistentState.currentSchemaVersion else {
            throw LocalDataStoreError.unsupportedSchema(
                found: state.schemaVersion,
                supported: PersistentState.currentSchemaVersion
            )
        }

        let validatedAccounts = try state.accounts.map { try $0.validated() }
        guard Set(validatedAccounts.map(\.id)).count == validatedAccounts.count else {
            throw LocalDataStoreError.duplicateAccountIdentifier
        }

        let accountsByIdentifier = Dictionary(
            uniqueKeysWithValues: validatedAccounts.map { ($0.id, $0) }
        )
        guard Set(state.snapshots.map(\.id)).count == state.snapshots.count else {
            throw LocalDataStoreError.invalidSnapshot
        }
        for snapshot in state.snapshots {
            guard let account = accountsByIdentifier[snapshot.accountID] else {
                throw LocalDataStoreError.orphanedSnapshot
            }
            guard snapshot.source.isCompatible(with: account.kind) else {
                throw LocalDataStoreError.invalidSnapshot
            }
            guard
                snapshot.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                isValidNonnegative(snapshot.totalTokens),
                isValidNonnegative(snapshot.inputTokens),
                isValidNonnegative(snapshot.cachedInputTokens),
                isValidNonnegative(snapshot.outputTokens),
                isValidNonnegative(snapshot.requests),
                snapshot.costUSD.value.map({ $0.isFinite && $0 >= 0 }) ?? true,
                snapshot.resetAt.value.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true
            else {
                throw LocalDataStoreError.invalidSnapshot
            }
            if let allowance = snapshot.allowance.value {
                _ = try allowance.validated()
            }
            if let reportingPeriod = snapshot.reportingPeriod {
                _ = try reportingPeriod.validated()
            }
            if let quotaWindows = snapshot.quotaWindows.value {
                _ = try quotaWindows.map { try $0.validated() }
            }
            if let bankedResetCredits = snapshot.bankedResetCredits.value {
                _ = try bankedResetCredits.validated()
            }
            if let models = snapshot.modelUsage.value {
                guard models.allSatisfy({ usage in
                    !usage.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && usage.inputTokens >= 0
                        && usage.cachedInputTokens >= 0
                        && usage.outputTokens >= 0
                        && (usage.requests.map { $0 >= 0 } ?? true)
                        && hasNonoverflowingSum([usage.inputTokens, usage.outputTokens])
                }) else {
                    throw LocalDataStoreError.invalidSnapshot
                }
            }
            if let dailyUsage = snapshot.dailyUsage.value {
                guard dailyUsage.allSatisfy({ point in
                    point.date.timeIntervalSinceReferenceDate.isFinite
                        && point.inputTokens >= 0
                        && point.cachedInputTokens >= 0
                        && point.outputTokens >= 0
                        && point.unattributedTokens >= 0
                        && (point.requests.map { $0 >= 0 } ?? true)
                        && point.costUSD.isFinite
                        && point.costUSD >= 0
                        && hasNonoverflowingSum([
                            point.inputTokens,
                            point.outputTokens,
                            point.unattributedTokens
                        ])
                }) else {
                    throw LocalDataStoreError.invalidSnapshot
                }
            }
        }
    }

    private func isValidNonnegative(_ metric: Metric<Int>) -> Bool {
        metric.value.map { $0 >= 0 } ?? true
    }

    private static func isCompatible(snapshotSource: String, accountKind: String) -> Bool {
        switch snapshotSource {
        case "manual":
            true
        case "chatGPTAppServer":
            ["chatGPTPlus", "chatGPTPro", "chatGPTSubscription"].contains(accountKind)
        case "claudeCodeOAuth":
            ["claudePro", "claudeMax", "claudeSubscription"].contains(accountKind)
        case "openAIAdminAPI":
            accountKind == "openAIAPI"
        case "anthropicAdminAPI":
            accountKind == "anthropicAPI"
        default:
            true
        }
    }

    private func hasNonoverflowingSum(_ values: [Int]) -> Bool {
        var total = 0
        for value in values {
            guard value >= 0 else { return false }
            let (updated, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return false }
            total = updated
        }
        return true
    }
}

private struct StateMigrationResult {
    let data: Data
    let didMigrate: Bool
}
