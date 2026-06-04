import SwiftUI
import AutorotaKit
#if canImport(MessageUI)
import MessageUI
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Pre-staged checklist of recipients for the Bulk Send flow. Each row taps
/// through to a pre-filled OS composer (iMessage / Mail) or a deep link
/// (WhatsApp). MFCompose channels auto-mark on the delegate callback;
/// URL-scheme channels show "Opened" with a manual "Mark sent" toggle.
struct BulkSendChecklistView: View {

    let weekStart: String
    let service: AutorotaServiceProtocol
    @Environment(\.dismiss) private var dismiss

    @State private var employees: [FfiEmployee] = []
    @State private var schedule: FfiWeekSchedule?
    @State private var queue: [BulkSendQueueItem] = []
    @State private var skipped: [BulkSendSkippedItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var showSkipList = false

    // Composer presentation state
    #if os(iOS)
    @State private var iMessageTarget: BulkSendQueueItem?
    @State private var mailTarget: BulkSendQueueItem?
    #endif

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Bulk Send")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    if !queue.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Mark all sent") { markAllSent() }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("More actions")
                        }
                    }
                }
                .task { await load() }
                .errorAlert($error)
                .navigationDestination(isPresented: $showSkipList) {
                    BulkSendSkipListView(
                        skipped: skipped,
                        onRetry: { Task { await retrySkipped() } }
                    )
                }
                #if os(iOS)
                .sheet(item: $iMessageTarget) { item in
                    if MessageComposeView.canSend, case .iMessage(let phone) = item.channel {
                        MessageComposeView(
                            recipient: phone,
                            body: item.body,
                            onResult: { result in
                                handleMessageResult(item: item, result: result)
                                iMessageTarget = nil
                            }
                        )
                    } else {
                        deviceCannotSendView(channel: "iMessage / SMS") { iMessageTarget = nil }
                    }
                }
                .sheet(item: $mailTarget) { item in
                    if MailComposeView.canSend, case .email(let address) = item.channel {
                        MailComposeView(
                            recipient: address,
                            subject: emailSubject(),
                            body: item.body,
                            onResult: { result, _ in
                                handleMailResult(item: item, result: result)
                                mailTarget = nil
                            }
                        )
                    } else {
                        deviceCannotSendView(channel: "Mail") { mailTarget = nil }
                    }
                }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 440, idealHeight: 600)
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading recipients…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if queue.isEmpty && skipped.isEmpty {
            ContentUnavailableView(
                "No Recipients",
                systemImage: "person.crop.circle.badge.xmark",
                description: Text("There are no employees to send the rota to.")
            )
        } else {
            List {
                if !queue.isEmpty {
                    Section {
                        ForEach($queue) { $item in
                            row(for: $item)
                        }
                    } header: {
                        Text("Ready (\(queue.count))")
                    } footer: {
                        Text("Tapping a row opens a draft. iMessage and Mail auto-mark when you tap Send. WhatsApp opens a draft you'll need to send manually.")
                    }
                }

                if !skipped.isEmpty {
                    Section {
                        Button {
                            showSkipList = true
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("\(skipped.count) skipped — view reasons")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        #if os(macOS)
                        .buttonStyle(.plain)
                        #endif
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for binding: Binding<BulkSendQueueItem>) -> some View {
        let item = binding.wrappedValue
        Button {
            send(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.channel.icon)
                    .frame(width: 24)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.employee.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(item.channel.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusPill(item.status)
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !item.channel.hasSendCallback && item.status != .sent {
                Button("Mark sent") {
                    binding.wrappedValue.status = .sent
                }
                .tint(.green)
            }
            if item.status != .pending {
                Button("Reset") {
                    binding.wrappedValue.status = .pending
                }
                .tint(.gray)
            }
        }
    }

    @ViewBuilder
    private func statusPill(_ status: BulkSendQueueItem.SendStatus) -> some View {
        switch status {
        case .pending:
            Text("Pending")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .opened:
            Text("Opened")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
        case .sent:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("Sent")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        case .failed(let reason):
            Text("Failed: \(reason)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func deviceCannotSendView(channel: String, onClose: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("\(channel) isn't available on this device.")
                .multilineTextAlignment(.center)
            Button("Close", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func send(_ item: BulkSendQueueItem) {
        switch item.channel {
        case .iMessage:
            #if os(iOS)
            iMessageTarget = item
            #else
            // macOS skip-list catches this; defensive fallthrough.
            error = "iMessage isn't supported on macOS."
            #endif

        case .email(let address):
            #if os(iOS)
            mailTarget = item
            #else
            let ok = MacMailDispatcher.compose(
                recipient: address, subject: emailSubject(), body: item.body
            )
            updateStatus(for: item.id, to: ok ? .opened : .failed(reason: "Mail not available"))
            #endif

        case .whatsApp(let phone):
            openWhatsApp(phone: phone, body: item.body, itemId: item.id)
        }
    }

    private func openWhatsApp(phone: String, body: String, itemId: Int64) {
        let digits = phone.filter { $0.isNumber }
        var comps = URLComponents(string: "https://wa.me/\(digits)")
        comps?.queryItems = [URLQueryItem(name: "text", value: body)]
        guard let url = comps?.url else {
            updateStatus(for: itemId, to: .failed(reason: "Invalid phone"))
            return
        }
        #if canImport(UIKit)
        UIApplication.shared.open(url) { ok in
            updateStatus(for: itemId, to: ok ? .opened : .failed(reason: "Couldn't open WhatsApp"))
        }
        #elseif canImport(AppKit)
        let ok = NSWorkspace.shared.open(url)
        updateStatus(for: itemId, to: ok ? .opened : .failed(reason: "Couldn't open WhatsApp"))
        #endif
    }

    #if os(iOS)
    private func handleMessageResult(item: BulkSendQueueItem, result: MessageComposeResult) {
        switch result {
        case .sent:
            updateStatus(for: item.id, to: .sent)
        case .failed:
            updateStatus(for: item.id, to: .failed(reason: "Couldn't send"))
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func handleMailResult(item: BulkSendQueueItem, result: MFMailComposeResult) {
        switch result {
        case .sent:
            updateStatus(for: item.id, to: .sent)
        case .failed:
            updateStatus(for: item.id, to: .failed(reason: "Couldn't send"))
        case .cancelled, .saved:
            break
        @unknown default:
            break
        }
    }
    #endif

    private func updateStatus(for id: Int64, to status: BulkSendQueueItem.SendStatus) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].status = status
    }

    private func markAllSent() {
        for i in queue.indices { queue[i].status = .sent }
    }

    private func emailSubject() -> String {
        "Rota for week of \(weekStart)"
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let employeesAsync = service.listEmployees()
            async let scheduleAsync = service.getWeekSchedule(weekStart: weekStart)
            employees = try await employeesAsync
            schedule = try await scheduleAsync
            rebuildQueue()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func rebuildQueue() {
        let entries = schedule?.entries ?? []
        let settings = BulkSendSettings.current

        var ready: [BulkSendQueueItem] = []
        var skip: [BulkSendSkippedItem] = []

        for emp in employees where !emp.deleted {
            let resolution = BulkSendDispatcher.resolve(employee: emp, entries: entries)
            switch resolution {
            case .ready(let channel):
                let body = MessageBodyBuilder.build(
                    employee: emp, weekStart: weekStart,
                    schedule: schedule, settings: settings
                )
                ready.append(BulkSendQueueItem(
                    employee: emp, channel: channel, body: body, status: .pending
                ))
            case .skip(let reason):
                skip.append(BulkSendSkippedItem(employee: emp, reason: reason))
            }
        }

        ready.sort { $0.employee.displayName.localizedCaseInsensitiveCompare($1.employee.displayName) == .orderedAscending }
        skip.sort { $0.employee.displayName.localizedCaseInsensitiveCompare($1.employee.displayName) == .orderedAscending }

        queue = ready
        skipped = skip
    }

    /// Reload employees (the user may have just edited contact info from the
    /// skip-list page) and re-run resolution. Existing queue rows preserve
    /// their `status` so a half-finished send isn't reset.
    private func retrySkipped() async {
        do {
            employees = try await service.listEmployees()
        } catch {
            self.error = userFacingMessage(error)
            return
        }
        let oldStatuses = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0.status) })
        rebuildQueue()
        for i in queue.indices {
            if let prior = oldStatuses[queue[i].id] {
                queue[i].status = prior
            }
        }
        showSkipList = false
    }
}
