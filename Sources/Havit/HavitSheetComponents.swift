import SwiftUI

struct HavitSheetHeader: View {
    let title: String
    let actionIcon: String
    let actionLabel: String
    var actionEnabled = true
    var actionProminent = false
    let onClose: () -> Void
    let onAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.34))
                .frame(width: 38, height: 5).padding(.top, 10).padding(.bottom, 18)
            HStack(spacing: 12) {
                Button(action: onClose) { control("xmark", prominent: false) }
                    .buttonStyle(.plain).accessibilityLabel("Cerrar")
                Spacer(minLength: 0)
                Text(title).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Button(action: onAction) { control(actionIcon, prominent: actionProminent && actionEnabled) }
                    .buttonStyle(.plain).accessibilityLabel(actionLabel)
                    .disabled(!actionEnabled).opacity(actionEnabled ? 1 : 0.45)
            }
            .padding(.horizontal, 20)
        }
    }

    private func control(_ icon: String, prominent: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white).frame(width: 44, height: 44)
            .background(prominent ? Color(red: 0.12, green: 0.53, blue: 1) : .white.opacity(0.08), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.8))
    }
}

private struct HavitSheetSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                if #available(iOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular.tint(.black.opacity(0.24)), in: UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34))
                        .ignoresSafeArea()
                } else {
                    UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34)
                        .fill(.ultraThinMaterial)
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34).stroke(.white.opacity(0.16), lineWidth: 0.9))
                        .ignoresSafeArea()
                }
            }
    }
}

private struct HavitInsetCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.11), lineWidth: 0.8))
    }
}

extension View {
    func havitSheetSurface() -> some View { modifier(HavitSheetSurface()) }
    func havitInsetCard() -> some View { modifier(HavitInsetCard()) }
}
