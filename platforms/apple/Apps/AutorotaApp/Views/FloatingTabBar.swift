import SwiftUI

#if os(iOS)
/// A floating glass bottom tab bar. Used on iPad to relocate navigation off
/// the iPadOS 26 default top tab bar, matching the iPhone bottom tab bar.
/// Bound to the same `TabSelection` state as the underlying `TabView`, so
/// taps drive content paging without re-implementing it.
struct FloatingTabBar: View {
    let pages: [TabPage]
    @Binding var selection: TabSelection

    var body: some View {
        HStack(spacing: 8) {
            ForEach(pages) { page in itemButton(page) }
        }
        .padding(8)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }

    @ViewBuilder
    private func itemButton(_ page: TabPage) -> some View {
        let isSelected = selection == .page(page)
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                selection = .page(page)
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                Text(page.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .frame(minWidth: 80, minHeight: 56)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(.tint.opacity(0.18))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.titleString)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
