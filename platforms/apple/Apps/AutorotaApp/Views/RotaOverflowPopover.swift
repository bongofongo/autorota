import SwiftUI

/// One row of the Rota overflow popover.
struct RotaOverflowAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    let action: () -> Void
}

/// Custom anchored popover used as the overflow menu for the Rota page.
/// Triggered from either the portrait `Tab(role: .search)` dots tab or the
/// landscape floating `.glassEffect` button — both flip the same
/// `RotaUIBridge.overflowOpen` flag, so this single overlay serves both.
///
/// Visually it scales in from the bottom-trailing corner like a native menu,
/// uses Liquid Glass material to match the dots button, and dismisses on
/// outside tap or row selection.
private struct RowMaxWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RotaOverflowPopover: View {
    let actions: [RotaOverflowAction]
    @Binding var isPresented: Bool
    @State private var rowWidth: CGFloat = 0
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// In landscape iPhone the dots is a floating button inside RotaView
    /// (~52pt tall, padding 20). In portrait it's the system tab bar dots,
    /// which sits just below RotaView's bottom edge.
    private var bottomPadding: CGFloat {
        #if os(iOS)
        return verticalSizeClass == .compact ? 84 : 12
        #else
        return 12
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Tap-outside dismiss backdrop.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            action.action()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(action.title)
                                .font(.body)
                                .foregroundStyle(action.role == .destructive ? Color.red : Color.primary)
                            Spacer(minLength: 10)
                            Image(systemName: action.systemImage)
                                .font(.body)
                                .foregroundStyle(action.role == .destructive ? Color.red : Color.primary)
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .frame(width: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowMaxWidthKey.self,
                                    value: geo.size.width
                                )
                            }
                        )
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .fixedSize()
            .onPreferenceChange(RowMaxWidthKey.self) { newValue in
                if newValue > rowWidth { rowWidth = newValue }
            }
            .padding(.trailing, 20)
            .padding(.bottom, bottomPadding)
            .transition(
                .scale(scale: 0.85, anchor: .bottomTrailing)
                .combined(with: .opacity)
            )
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            isPresented = false
        }
    }
}
