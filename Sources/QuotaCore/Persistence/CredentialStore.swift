import Foundation
import Security

public struct ProviderCredential: Equatable, Sendable {
    public let secret: String

    public init(secret: String) throws {
        let normalized = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CredentialStoreError.emptyCredential
        }
        guard !normalized.contains("\n"), !normalized.contains("\r") else {
            throw CredentialStoreError.invalidCredentialCharacters
        }
        self.secret = normalized
    }
}

public protocol CredentialStoring: Sendable {
    func save(_ credential: ProviderCredential, for accountID: UUID) throws
    func credential(for accountID: UUID) throws -> ProviderCredential?
    func deleteCredential(for accountID: UUID) throws
}

public enum CredentialStoreError: LocalizedError, Equatable {
    case emptyCredential
    case invalidCredentialCharacters
    case invalidEncoding
    case keychainFailure(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "Enter a valid admin API key."
        case .invalidCredentialCharacters:
            "The admin API key contains unsupported characters."
        case .invalidEncoding:
            "The saved credential could not be read."
        case let .keychainFailure(operation, status):
            "Keychain \(operation) failed (\(status))."
        }
    }
}

public struct KeychainCredentialStore: CredentialStoring {
    private let service: String

    public init(service: String = "com.jbergvinson.quota.provider-credential") {
        self.service = service
    }

    public func save(_ credential: ProviderCredential, for accountID: UUID) throws {
        let credentialData = Data(credential.secret.utf8)
        let lookup = baseQuery(for: accountID)
        let update: [CFString: Any] = [
            kSecValueData: credentialData
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = lookup
            item[kSecValueData] = credentialData
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainFailure(operation: "save", status: addStatus)
            }
        default:
            throw CredentialStoreError.keychainFailure(operation: "update", status: updateStatus)
        }
    }

    public func credential(for accountID: UUID) throws -> ProviderCredential? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(operation: "read", status: status)
        }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }
        return try ProviderCredential(secret: secret)
    }

    public func deleteCredential(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(operation: "delete", status: status)
        }
    }

    private func baseQuery(for accountID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID.uuidString
        ]
    }
}
