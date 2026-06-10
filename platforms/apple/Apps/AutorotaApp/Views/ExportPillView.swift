import SwiftUI
import UniformTypeIdentifiers
import AutorotaKit

/// Drag payload for the export sandbox: either a field pill or a role pill.
struct ExportPillPayload: Codable, Transferable, Hashable {
    enum Kind: Codable, Hashable {
        case field(ExportField)
        case role(id: Int64, name: String)
    }

    let kind: Kind

    static var transferRepresentation: some TransferRepresentation {
        // Plain JSON keeps the payload in-app draggable without declaring a
        // custom exported UTType in the (generated) Info.plist.
        CodableRepresentation(contentType: .json)
    }

    static func field(_ field: ExportField) -> Self { .init(kind: .field(field)) }
    static func role(_ role: FfiRole) -> Self { .init(kind: .role(id: role.id, name: role.name)) }
}

/// Capsule chip for a draggable sandbox pill.
struct ExportPillView: View {
    let label: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    var compact = false

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
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
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
