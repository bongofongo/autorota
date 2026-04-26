import SwiftUI

#if os(iOS)
/// A floating glass tab bar laid out either vertically (rail) or horizontally
/// (bottom bar). Used on iPad to relocate navigation off the iPadOS 26 default
/// top tab bar. Bound to the same `TabSelection` state as the underlying
/// `TabView`, so taps drive content paging without re-implementing it.
struct FloatingTabBar: View {
    let pages: [TabPage]
    @Binding var selection: TabSelection
    let axis: Axis

    private var isHorizontal: Bool { axis == .horizontal }

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 6) {
                    ForEach(pages) { page in itemButton(page) }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(pages) { page in itemButton(page) }
                }
            }
        }
        .padding(isHorizontal ? 8 : 8)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: isHorizontal ? 28 : 28, style: .continuous)
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
            VStack(spacing: isHorizontal ? 3 : 2) {
                Image(systemName: page.systemImage)
                    .font(.system(size: isHorizontal ? 22 : 20, weight: .semibold))
                Text(page.title)
                    .font(isHorizontal ? .caption2 : .caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, isHorizontal ? 7 : 8)
            .padding(.horizontal, isHorizontal ? 14 : 6)
            .frame(
                minWidth: isHorizontal ? 80 : 56,
                minHeight: isHorizontal ? 56 : 56
            )
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

/// User-selectable rail edge. Stored as `String` raw value via `@AppStorage`.
enum TabBarEdge: String, CaseIterable, Identifiable {
    case leading
    case trailing

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .leading: "Leading"
        case .trailing: "Trailing"
        }
    }

    var alignment: Alignment {
        switch self {
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}
#endif
