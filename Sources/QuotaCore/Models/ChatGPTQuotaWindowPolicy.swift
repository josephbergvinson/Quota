import Foundation

/// Product policy for rate-limit buckets that Codex reports but Quota does not use for
/// regular account rotation. ChatGPT's Codex service currently returns several model and
/// duration buckets, but Quota's planner is intentionally scoped to the regular Codex
/// one-week allowance. Keep the match tolerant of provider punctuation/casing changes while
/// requiring the known Codex identity and weekly duration.
enum ChatGPTQuotaWindowPolicy {
    static let codexWeeklyDurationMinutes = 10_080

    private static let sparkModelMarker = "gpt53codexspark"
    private static let sparkLimitMarker = "codexbengalfox"
    private static let codexIdentifier = "codex"

    static func isSupportedWindow(
        identifier: String?,
        name: String?,
        durationMinutes: Int64?
    ) -> Bool {
        guard durationMinutes == Int64(codexWeeklyDurationMinutes) else {
            return false
        }

        let normalizedValues = [identifier, name]
            .compactMap { $0 }
            .map(normalized)
        guard !normalizedValues.contains(where: isSparkValue) else { return false }

        return normalizedValues.contains { value in
            value == codexIdentifier || value.hasPrefix("\(codexIdentifier)1week")
        }
    }

    static func isSupportedWindow(_ window: QuotaWindow) -> Bool {
        guard let durationMinutes = window.durationMinutes else { return false }
        return isSupportedWindow(
            identifier: window.identifier,
            name: window.name,
            durationMinutes: Int64(durationMinutes)
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
