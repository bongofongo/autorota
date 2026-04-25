import SwiftUI
import AutorotaKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Reasons grouped, one row per skipped employee. Toolbar offers Retry
/// (re-fetch employees and re-resolve) and Copy (tab-separated list to
/// the system pasteboard for manual follow-up).
struct BulkSendSkipListView: View {

    let skipped: [BulkSendSkippedItem]
    let onRetry: () -> Void

    var body: some View {
        List {
            ForEach(grouped) { group in
                Section {
                    ForEach(group.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.employee.displayName)
                                .font(.body)
                            if let detail = item.reason.detail {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            if let extra = contactDetail(for: item) {
                                Text(extra)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(group.reason.label)
                }
            }
        }
        .navigationTitle("Skipped")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    Button {
                        copyToPasteboard()
                    } label: {
                        Label("Copy List", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Grouping

    private struct Group: Identifiable {
        let reason: BulkSendSkipReason
        let items: [BulkSendSkippedItem]
        var id: String { reason.label }
    }

    private var grouped: [Group] {
        let order: [BulkSendSkipReason] = [
            .noShifts,
            .noPhone,
            .noEmail,
            .noPreferredChannel,
            .channelUnsupportedOnPlatform,
        ]
        var seen: [(BulkSendSkipReason, [BulkSendSkippedItem])] = []
        for reason in order {
            let items = skipped.filter { sameKind($0.reason, reason) }
            if !items.isEmpty { seen.append((reason, items)) }
        }
        let invalids = skipped.filter {
            if case .invalidPhoneFormat = $0.reason { return true }
            return false
        }
        if !invalids.isEmpty {
            seen.append((.invalidPhoneFormat(value: ""), invalids))
        }
        return seen.map { Group(reason: $0.0, items: $0.1) }
    }

    /// Equality that ignores the `invalidPhoneFormat` payload so all
    /// invalid-phone rows group under one section header.
    private func sameKind(_ a: BulkSendSkipReason, _ b: BulkSendSkipReason) -> Bool {
        switch (a, b) {
        case (.noShifts, .noShifts),
             (.noPhone, .noPhone),
             (.noEmail, .noEmail),
             (.noPreferredChannel, .noPreferredChannel),
             (.channelUnsupportedOnPlatform, .channelUnsupportedOnPlatform):
            return true
        case (.invalidPhoneFormat, .invalidPhoneFormat):
            return true
        default:
            return false
        }
    }

    private func contactDetail(for item: BulkSendSkippedItem) -> String? {
        switch item.reason {
        case .noEmail:
            if let p = item.employee.phone, !p.isEmpty { return "Phone on file: \(p)" }
            return nil
        case .noPreferredChannel:
            if let p = item.employee.phone, !p.isEmpty { return "Phone on file: \(p)" }
            return nil
        case .channelUnsupportedOnPlatform:
            return "Switch this employee to email or WhatsApp."
        default:
            return nil
        }
    }

    // MARK: - Copy

    private func copyToPasteboard() {
        let lines = skipped.map { item -> String in
            let phone = item.employee.phone ?? ""
            let email = item.employee.email ?? ""
            return [item.employee.displayName, item.reason.label, phone, email]
                .joined(separator: "\t")
        }
        let text = lines.joined(separator: "\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
