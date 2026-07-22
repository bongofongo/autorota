import OSLog

/// Shared signposter for user-visible launch/load phases.
///
/// The XCUITest perf harness disables the boot animation, sync check, and
/// rates fetch, so launch-overlap wins are invisible there by design — these
/// signposts are how they're observed on a real launch. Inspect with the
/// os_signpost instrument, or live:
///
///   log stream --predicate 'subsystem == "com.toadmountain.autorota"'
enum PerfSignposts {
    static let poster = OSSignposter(
        subsystem: "com.toadmountain.autorota",
        category: .pointsOfInterest
    )
}
