import SwiftUI
import AutorotaKit

/// Capsule chip for a sandbox pill. `selected` renders the awaiting-a-bucket
/// state in the tap-to-place flow.
struct ExportPillView: View {
    let label: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    var compact = false
    var selected = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(label)
                .font(compact ? .caption2 : .caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? Spacing.sm : Spacing.md)
        .padding(.vertical, compact ? 3 : 6)
        .background(Capsule().fill(tint.opacity(selected ? 0.35 : 0.15)))
        .overlay(Capsule().strokeBorder(tint.opacity(selected ? 1 : 0.4), lineWidth: selected ? 1.5 : 1))
        .foregroundStyle(tint)
    }
}

extension ExportField {
    var systemImage: String {
        switch self {
        case .shiftName: return "tag"
        case .time: return "clock"
        case .role: return "person.text.rectangle"
        case .employeeName: return "person"
        case .cost: return "dollarsign.circle"
        }
    }
}
