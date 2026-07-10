import Foundation

/// Thread-safe sync-readable flag consulted by `GatedAutorotaService` on every
/// mutation. Updated by `LicenseService` whenever its state changes.
///
/// We can't use `@MainActor` here because mutation methods are called from
/// background tasks via async ViewModel work. A lock-protected mutable flag
/// is the simplest correct option.
final class LicenseGate: @unchecked Sendable {
    static let shared = LicenseGate()

    private let lock = NSLock()
    private var _isReadOnly: Bool = false
    private var _allowsMutation: Bool = true
    private var _isDemoActive: Bool = false

    /// Internal (not private) so tests can create isolated instances instead
    /// of mutating `.shared`, which races parallel test suites.
    init() {}

    var isReadOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isReadOnly && !_isDemoActive
    }

    var allowsMutation: Bool {
        lock.lock(); defer { lock.unlock() }
        return _allowsMutation || _isDemoActive
    }

    var isDemoActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isDemoActive
    }

    func update(state: LicenseState) {
        lock.lock(); defer { lock.unlock() }
        _isReadOnly = state.isReadOnly
        _allowsMutation = state.allowsMutation
    }

    /// Demo mode runs against a throwaway database, so mutations are safe
    /// regardless of license state (incl. pre-purchase `unset`). Cleared on
    /// demo exit; `update(state:)` semantics then apply again unchanged.
    func setDemoActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        _isDemoActive = active
    }
}
