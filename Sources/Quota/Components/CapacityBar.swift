import QuotaCore
import SwiftUI

struct CapacityBar: View {
    let capacity: AccountCapacity

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                if let remaining = capacity.remainingFraction {
                    Text(QuotaFormat.percentage(remaining))
                        .font(.title3.weight(.semibold))
                        .contentTransition(.numericText())
                    Text("left")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Capacity unavailable")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Text(capacity.status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(capacity.status.color)
            }

            if let remaining = capacity.remainingFraction {
                CapacityProgressIndicator(
                    remainingFraction: remaining,
                    status: capacity.status
                )
            }
        }
    }
}

struct CapacityProgressIndicator: View {
    let remainingFraction: Double
    let status: CapacityStatus

    private var clampedFraction: Double {
        min(1, max(0, remainingFraction))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(status.color.opacity(0.18))
                Capsule()
                    .fill(status.color)
                    .frame(width: proxy.size.width * clampedFraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Remaining capacity")
        .accessibilityValue(
            "\(QuotaFormat.percentage(clampedFraction)), \(status.label)"
        )
    }
}
