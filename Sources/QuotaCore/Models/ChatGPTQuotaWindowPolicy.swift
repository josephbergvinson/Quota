import Foundation

/// Product policy for rate-limit buckets that Codex reports but Quota does not use for
/// regular account rotation. Keep the match tolerant of provider punctuation/casing changes,
/// require the known Codex identity, and apply the subscription tier's supported durations.
enum ChatGPTQuotaWindowPolicy {
    static let codexFiveHourDurationMinutes = 300
    static let codexWeeklyDurationMinutes = 10_080

    private static let sparkModelMarker = "gpt53codexspark"
    private static let sparkLimitMarker = "codexbengalfox"
    private static let codexIdentifier = "codex"

    static func isSupportedWindow(
        identityValues: [String?],
        durationMinutes: Int64?,
        accountKind: AccountKind
    ) -> Bool {
        let normalizedValues = identityValues
            .compactMap { $0 }
            .map(normalized)
        guard !normalizedValues.contains(where: isSparkValue) else { return false }
        guard normalizedValues.contains(where: { value in
            value == codexIdentifier
                || value == "\(codexIdentifier)primary"
                || value == "\(codexIdentifier)secondary"
                || value.hasPrefix("\(codexIdentifier)5hour")
                || value.hasPrefix("\(codexIdentifier)1week")
        }) else {
            return false
        }

        switch accountKind {
        case .chatGPTPlus:
            return durationMinutes == Int64(codexFiveHourDurationMinutes)
                || durationMinutes == Int64(codexWeeklyDurationMinutes)
        case .chatGPTPro, .chatGPTSubscription:
            return durationMinutes == Int64(codexWeeklyDurationMinutes)
        case .openAIAPI, .claudePro, .claudeMax, .claudeSubscription, .anthropicAPI:
            return false
        }
    }

    static func isSupportedWindow(
        _ window: QuotaWindow,
        accountKind: AccountKind
    ) -> Bool {
        guard let durationMinutes = window.durationMinutes else { return false }
        return isSupportedWindow(
            identityValues: [window.identifier, window.name],
            durationMinutes: Int64(durationMinutes),
            accountKind: accountKind
        )
    }

    private static func isSparkValue(_ value: String) -> Bool {
        value.contains(sparkModelMarker) || value.contains(sparkLimitMarker)
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
