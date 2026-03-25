import SwiftUI
import AutorotaKit

/// A 7-column × 24-row grid showing availability state per weekday/hour.
/// When `isEditable` is true, tapping a cell cycles through No → Maybe → Yes.
struct AvailabilityGridView: View {

    let slots: [AvailabilitySlot]
    let isEditable: Bool
    var onChange: (([AvailabilitySlot]) -> Void)?

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let businessHours = Array(6...22)  // show 06:00–22:00 by default

    // Build a lookup for fast access
    private var lookup: [String: String] {
        Dictionary(slots.map { ("\($0.weekday):\($0.hour)", $0.state) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                // Header row
                HStack(spacing: 2) {
                    Text("").frame(width: 36)
                    ForEach(Self.weekdays, id: \.self) { day in
                        Text(day)
                            .font(.caption2.bold())
                            .frame(width: 34)
                            .multilineTextAlignment(.center)
                    }
                }

                // Hour rows
                ForEach(Self.businessHours, id: \.self) { hour in
                    HStack(spacing: 2) {
                        Text(String(format: "%02d", hour))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)

                        ForEach(Self.weekdays, id: \.self) { day in
                            let key = "\(day):\(hour)"
                            let state = lookup[key] ?? "Maybe"
                            CellView(state: state, isEditable: isEditable) {
                                if isEditable { toggle(weekday: day, hour: hour) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func toggle(weekday: String, hour: Int) {
        var updated = slots
        if let idx = updated.firstIndex(where: { $0.weekday == weekday && $0.hour == UInt8(hour) }) {
            let next = cycled(updated[idx].state)
            if next == "Maybe" {
                // Maybe is the default — remove explicit entry to keep list compact
                updated.remove(at: idx)
            } else {
                updated[idx] = AvailabilitySlot(weekday: weekday, hour: UInt8(hour), state: next)
            }
        } else {
            // No explicit entry means Maybe; first tap → Yes
            updated.append(AvailabilitySlot(weekday: weekday, hour: UInt8(hour), state: "Yes"))
        }
        onChange?(updated)
    }

    private func cycled(_ state: String) -> String {
        switch state {
        case "Yes":   return "No"
        case "No":    return "Maybe"
        default:      return "Yes"
        }
    }
}

private struct CellView: View {
    let state: String
    let isEditable: Bool
    let onTap: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color(for: state))
            .frame(width: 34, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .onTapGesture { if isEditable { onTap() } }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "Yes":   return .green.opacity(0.75)
        case "No":    return .red.opacity(0.55)
        default:      return .yellow.opacity(0.45)
        }
    }
}
