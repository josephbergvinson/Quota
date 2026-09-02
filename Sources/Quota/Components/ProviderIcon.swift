import QuotaCore
import SwiftUI

struct ProviderIcon: View {
    let provider: ProviderKind
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(provider.tintColor.gradient, in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityLabel(provider.displayName)
    }
}
