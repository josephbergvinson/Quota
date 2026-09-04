import Foundation

public struct UsageProviderRegistry: Sendable {
    private let providers: [UsageDataSourceKind: any UsageProvider]

    public init(providers: [any UsageProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.dataSourceKind, $0) })
    }

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        chatGPTAccountsDirectoryURL: URL? = nil,
        claudeCodeAccountsDirectoryURL: URL? = nil
    ) {
        var providers: [any UsageProvider] = [
            OpenAIUsageProvider(httpClient: httpClient),
            AnthropicUsageProvider(httpClient: httpClient)
        ]
        if let chatGPTAccountsDirectoryURL {
            providers.append(
                ChatGPTUsageProvider(accountsDirectoryURL: chatGPTAccountsDirectoryURL)
            )
        }
        if let claudeCodeAccountsDirectoryURL {
            providers.append(
                ClaudeCodeUsageProvider(accountsDirectoryURL: claudeCodeAccountsDirectoryURL)
            )
        }
        self.init(providers: providers)
    }

    public func provider(for account: ConnectedAccount) -> (any UsageProvider)? {
        providers[account.kind.dataSource]
    }
}

public actor UsageRefreshService {
    private let registry: UsageProviderRegistry
    private let credentialStore: any CredentialStoring

    public init(
        registry: UsageProviderRegistry = UsageProviderRegistry(),
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.registry = registry
        self.credentialStore = credentialStore
    }

    public func refresh(account: ConnectedAccount, now: Date = Date()) async throws -> ProviderFetchResult {
        guard let provider = registry.provider(for: account) else {
            throw ProviderError.unsupportedAccount
        }
        let credential: ProviderCredential? = if account.kind.requiresCredential {
            try credentialStore.credential(for: account.id)
        } else {
            nil
        }
        return try await provider.fetchUsage(for: account, credential: credential, now: now)
    }
}
