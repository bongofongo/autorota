import Foundation
import AutorotaKit

/// Resolved channel for one recipient. iMessage and SMS share the `sms:`
/// scheme on iOS — the OS routes to iMessage when both ends support it,
/// otherwise SMS — so we treat them as a single transport.
enum BulkSendChannel: Equatable {
    case iMessage(phone: String)
    case whatsApp(phone: String)
    case email(address: String)

    var label: String {
        switch self {
        case .iMessage: "iMessage / SMS"
        case .whatsApp: "WhatsApp"
        case .email: "Email"
        }
    }

    var icon: String {
        switch self {
        case .iMessage: "message.fill"
        case .whatsApp: "bubble.left.and.bubble.right.fill"
        case .email: "envelope.fill"
        }
    }

    /// Whether the OS gives us a delegate callback when the user taps Send,
    /// allowing the checklist to auto-mark the row. URL-scheme channels
    /// (WhatsApp web/app) return nothing, so the row stays in "Opened"
    /// until the user manually marks it sent.
    var hasSendCallback: Bool {
        switch self {
        case .iMessage, .email: true
        case .whatsApp: false
        }
    }
}

enum BulkSendSkipReason: Equatable {
    case noShifts
    case noPhone
    case noEmail
    case noPreferredChannel
    case invalidPhoneFormat(value: String)
    case channelUnsupportedOnPlatform

    var label: String {
        switch self {
        case .noShifts: "No shifts this week"
        case .noPhone: "No phone number"
        case .noEmail: "No email address"
        case .noPreferredChannel: "No preferred channel set"
        case .invalidPhoneFormat: "Invalid phone number"
        case .channelUnsupportedOnPlatform: "iMessage requires iOS"
        }
    }

    var detail: String? {
        if case let .invalidPhoneFormat(value) = self { return value }
        return nil
    }
}

enum BulkSendResolution: Equatable {
    case ready(BulkSendChannel)
    case skip(BulkSendSkipReason)
}

enum BulkSendPlatform {
    case iOS
    case macOS

    static var current: BulkSendPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

/// Pure resolution logic. Held outside the view so it's unit-testable
/// against `MockAutorotaService` without touching SwiftUI.
enum BulkSendDispatcher {

    /// Decide which channel (if any) to use for `employee` this week.
    /// `entries` is the full list of `FfiScheduleEntry` for the rota; this
    /// function filters by `employee.id` for the zero-shift check.
    static func resolve(
        employee: FfiEmployee,
        entries: [FfiScheduleEntry],
        platform: BulkSendPlatform = .current
    ) -> BulkSendResolution {
        let hasShifts = entries.contains { $0.employeeId == employee.id }
        if !hasShifts {
            return .skip(.noShifts)
        }
        return resolveContact(employee: employee, platform: platform)
    }

    /// Channel resolution without the zero-shift gate. Used by the share
    /// sheet's direct-send button, where sending an empty rota is allowed.
    static func resolveContact(
        employee: FfiEmployee,
        platform: BulkSendPlatform = .current
    ) -> BulkSendResolution {
        let preferred = employee.preferredContact ?? ""
        let phone = employee.phone?.trimmingCharacters(in: .whitespaces)
        let email = employee.email?.trimmingCharacters(in: .whitespaces)
        let hasPhone = !(phone?.isEmpty ?? true)
        let hasEmail = !(email?.isEmpty ?? true)

        switch preferred {
        case "imessage":
            if platform == .macOS {
                if hasEmail { return .ready(.email(address: email!)) }
                return .skip(.channelUnsupportedOnPlatform)
            }
            if !hasPhone {
                if hasEmail { return .ready(.email(address: email!)) }
                return .skip(.noPhone)
            }
            return validatePhone(phone!).map { .ready(.iMessage(phone: $0)) }
                ?? .skip(.invalidPhoneFormat(value: phone!))

        case "whatsapp":
            if !hasPhone {
                if hasEmail { return .ready(.email(address: email!)) }
                return .skip(.noPhone)
            }
            return validatePhone(phone!).map { .ready(.whatsApp(phone: $0)) }
                ?? .skip(.invalidPhoneFormat(value: phone!))

        default:
            if hasEmail { return .ready(.email(address: email!)) }
            if hasPhone { return .skip(.noPreferredChannel) }
            return .skip(.noPhone)
        }
    }

    /// Returns the E.164-normalized phone if the employee's `preferredContact`
    /// rules consider it valid, else nil. Auto-detects country from the
    /// stored value (it's already normalized at save-time).
    private static func validatePhone(_ raw: String) -> String? {
        let detected = PhoneCountry.detect(from: raw)
        let country = detected == .other
            ? PhoneCountry(regionCode: Locale.current.region?.identifier ?? "")
            : detected
        let formatter = PhoneNumberFormatter(country: country)
        guard formatter.isValid(raw) else { return nil }
        return formatter.normalizeForStorage(raw)
    }
}

/// One row in the checklist UI. Identifiable by employee id.
struct BulkSendQueueItem: Identifiable, Equatable {
    let employee: FfiEmployee
    let channel: BulkSendChannel
    let body: String
    var status: SendStatus

    var id: Int64 { employee.id }

    enum SendStatus: Equatable {
        case pending
        case opened   // user tapped row, deep link fired, no callback yet
        case sent
        case failed(reason: String)
    }
}

struct BulkSendSkippedItem: Identifiable, Equatable {
    let employee: FfiEmployee
    let reason: BulkSendSkipReason

    var id: Int64 { employee.id }
}
