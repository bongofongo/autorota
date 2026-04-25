import Foundation
import SwiftUI

enum Tier: String, CaseIterable, Codable, Sendable, Identifiable {
    case localManager = "local_manager"
    case employee     = "employee"
    case saas         = "saas"

    var id: String { rawValue }

    var isAvailable: Bool { self == .localManager }

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .localManager: "license.tier.local_manager.name"
        case .employee:     "license.tier.employee.name"
        case .saas:         "license.tier.saas.name"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .localManager: "license.tier.local_manager.description"
        case .employee:     "license.tier.employee.description"
        case .saas:         "license.tier.saas.description"
        }
    }

    var bulletKeys: [LocalizedStringKey] {
        switch self {
        case .localManager: [
            "license.tier.local_manager.bullet.1",
            "license.tier.local_manager.bullet.2",
            "license.tier.local_manager.bullet.3",
        ]
        case .employee: [
            "license.tier.employee.bullet.1",
            "license.tier.employee.bullet.2",
            "license.tier.employee.bullet.3",
        ]
        case .saas: [
            "license.tier.saas.bullet.1",
            "license.tier.saas.bullet.2",
            "license.tier.saas.bullet.3",
        ]
        }
    }

    var iconSystemName: String {
        switch self {
        case .localManager: "person.crop.square.filled.and.at.rectangle"
        case .employee:     "person.2.fill"
        case .saas:         "cloud.fill"
        }
    }
}

enum LicenseState: Equatable, Sendable {
    case unset
    case trial(startedAt: Date, daysRemaining: Int)
    case purchased(tier: Tier)
    case expired(previousTier: Tier)

    var isReadOnly: Bool {
        if case .expired = self { return true }
        return false
    }

    var allowsMutation: Bool {
        switch self {
        case .unset, .expired: false
        case .trial, .purchased: true
        }
    }

    var currentTier: Tier? {
        switch self {
        case .unset: nil
        case .trial: .localManager
        case .purchased(let t): t
        case .expired(let t): t
        }
    }

    var trialDaysRemaining: Int? {
        if case .trial(_, let days) = self { return days }
        return nil
    }
}

enum LicenseError: LocalizedError, Equatable {
    case readOnly
    case purchaseFailed(String)
    case trialAlreadyUsed
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .readOnly:
            String(localized: "license.error.read_only")
        case .purchaseFailed(let detail):
            String(localized: "license.error.purchase_failed") + ": " + detail
        case .trialAlreadyUsed:
            String(localized: "license.error.trial_used")
        case .networkUnavailable:
            String(localized: "license.error.network")
        }
    }
}

enum LicenseDuration {
    static let trialDays: Int = 7
}
