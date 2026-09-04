import QuotaCore
import SwiftUI

extension ProviderKind {
    var tintColor: Color {
        switch self {
        case .openAI:
            Color(red: 0.08, green: 0.58, blue: 0.45)
        case .anthropic:
            Color(red: 0.82, green: 0.42, blue: 0.27)
        }
    }

    var symbolName: String {
        switch self {
        case .openAI:
            "sparkles"
        case .anthropic:
            "sun.max.fill"
        }
    }
}

extension CapacityStatus {
    var color: Color {
        switch self {
        case .healthy:
            .green
        case .watch:
            .yellow
        case .low:
            .orange
        case .exhausted:
            .red
        case .stale, .unavailable:
            .secondary
        }
    }

    var label: String {
        switch self {
        case .healthy:
            "Available"
        case .watch:
            "Watch"
        case .low:
            "Low"
        case .exhausted:
            "Exhausted"
        case .stale:
            "Stale"
        case .unavailable:
            "Unknown"
        }
    }

    var indicatorSymbolName: String {
        switch self {
        case .healthy, .watch, .low:
            "circle.fill"
        case .exhausted:
            "xmark.octagon.fill"
        case .stale:
            "clock.fill"
        case .unavailable:
            "questionmark.circle"
        }
    }
}

enum QuotaFormat {
    static func compactNumber(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func amount(_ value: Double, unit: UsageUnit) -> String {
        switch unit {
        case .messages, .tokens, .credits:
            value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case .dollars:
            value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        case .percent:
            value.formatted(.number.precision(.fractionLength(0...1))) + "%"
        }
    }

    static func percentage(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
