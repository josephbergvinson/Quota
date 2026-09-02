import Foundation

/// Product policy for rate-limit buckets that Codex reports but Quota does not use for
/// regular account rotation. Keep the match tolerant of provider punctuation/casing changes,
/// while requiring the known Spark model marker or its provider metered-feature identifier.
enum ChatGPTQuotaWindowPolicy {
    private static let sparkModelMarker = "gpt53codexspark"
    private static let sparkLimitMarker = "codexbengalfox"

    static func isSparkWindow(identifier: String?, name: String?) -> Bool {
        [identifier, name]
            .compactMap { $0 }
            .map(normalized)
            .contains { value in
                value.contains(sparkModelMarker) || value.contains(sparkLimitMarker)
            }
    }

    static func isSparkWindow(_ window: QuotaWindow) -> Bool {
        isSparkWindow(identifier: window.identifier, name: window.name)
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
