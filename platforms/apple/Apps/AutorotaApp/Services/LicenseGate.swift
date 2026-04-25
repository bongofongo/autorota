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

    private init() {}

    var isReadOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isReadOnly
    }

    var allowsMutation: Bool {
        lock.lock(); defer { lock.unlock() }
        return _allowsMutation
    }

    func update(state: LicenseState) {
        lock.lock(); defer { lock.unlock() }
        _isReadOnly = state.isReadOnly
        _allowsMutation = state.allowsMutation
    }
}
