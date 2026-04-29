import SwiftUI

struct AppRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.body)
                if let subtitle {
                    Text(subtitle).font(AppFont.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.sm)
            trailing
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }
}

extension AppRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}
