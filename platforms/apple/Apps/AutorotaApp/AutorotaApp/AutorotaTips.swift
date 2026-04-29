import SwiftUI
import TipKit

/// Coach-mark tips surfaced once per install on the rich edit surfaces.
/// Configured globally from `AutorotaAppApp.init()`.
///
/// Tips are sequenced via `AutorotaEvents` donations so a fresh user sees at
/// most one tip per setup phase. Resetting `Tips.resetDatastore()` (replay
/// onboarding) clears donations and re-arms the chain.

enum AutorotaEvents {
    static let firstEmployeeAdded = Tips.Event(id: "first-employee-added")
    static let firstTemplateAdded = Tips.Event(id: "first-template-added")
    static let firstScheduleGenerated = Tips.Event(id: "first-schedule-generated")
}

struct EmployeesAddTip: Tip {
    var title: Text {
        Text("tip.employees.add.title")
    }
    var message: Text? {
        Text("tip.employees.add.message")
    }
    var image: Image? {
        Image(systemName: "person.badge.plus")
    }
    var rules: [Rule] {
        // Stops nagging once the user has actually added someone.
        #Rule(AutorotaEvents.firstEmployeeAdded) { $0.donations.count == 0 }
    }
}

struct ShiftTemplateAddTip: Tip {
    var title: Text {
        Text("tip.shifts.template.title")
    }
    var message: Text? {
        Text("tip.shifts.template.message")
    }
    var image: Image? {
        Image(systemName: "clock.badge.plus")
    }
    var rules: [Rule] {
        #Rule(AutorotaEvents.firstEmployeeAdded) { $0.donations.count > 0 }
        #Rule(AutorotaEvents.firstTemplateAdded) { $0.donations.count == 0 }
    }
}

struct RotaTwoPassTip: Tip {
    var title: Text {
        Text("tip.rota.twopass.title")
    }
    var message: Text? {
        Text("tip.rota.twopass.message")
    }
    var image: Image? {
        Image(systemName: "wand.and.stars")
    }
    var rules: [Rule] {
        #Rule(AutorotaEvents.firstTemplateAdded) { $0.donations.count > 0 }
        #Rule(AutorotaEvents.firstScheduleGenerated) { $0.donations.count == 0 }
    }
}

struct RotaShareTip: Tip {
    var title: Text {
        Text("tip.rota.share.title")
    }
    var message: Text? {
        Text("tip.rota.share.message")
    }
    var image: Image? {
        Image(systemName: "square.and.arrow.up")
    }
    var rules: [Rule] {
        #Rule(AutorotaEvents.firstScheduleGenerated) { $0.donations.count > 0 }
    }
}

struct ExportProfileTip: Tip {
    var title: Text {
        Text("tip.export.profile.title")
    }
    var message: Text? {
        Text("tip.export.profile.message")
    }
    var image: Image? {
        Image(systemName: "doc.text")
    }
    var rules: [Rule] {
        #Rule(AutorotaEvents.firstScheduleGenerated) { $0.donations.count > 0 }
    }
}

struct EditLogRestoreTip: Tip {
    var title: Text {
        Text("tip.editlog.restore.title")
    }
    var message: Text? {
        Text("tip.editlog.restore.message")
    }
    var image: Image? {
        Image(systemName: "arrow.uturn.backward.circle")
    }
    var rules: [Rule] {
        #Rule(AutorotaEvents.firstScheduleGenerated) { $0.donations.count > 0 }
    }
}

struct EmployeeRolesTip: Tip {
    var title: Text {
        Text("tip.employee.roles.title")
    }
    var message: Text? {
        Text("tip.employee.roles.message")
    }
    var image: Image? {
        Image(systemName: "person.text.rectangle")
    }
}

struct AvailabilityModeTip: Tip {
    var title: Text {
        Text("tip.availability.mode.title")
    }
    var message: Text? {
        Text("tip.availability.mode.message")
    }
    var image: Image? {
        Image(systemName: "rectangle.split.2x1")
    }
}

struct AvailabilityCycleTip: Tip {
    var title: Text {
        Text("tip.availability.cycle.title")
    }
    var message: Text? {
        Text("tip.availability.cycle.message")
    }
    var image: Image? {
        Image(systemName: "hand.tap")
    }
}

struct AvailabilityDragTip: Tip {
    static let cycleDismissed = Tips.Event(id: "availability-cycle-dismissed")

    var title: Text {
        Text("tip.availability.drag.title")
    }
    var message: Text? {
        Text("tip.availability.drag.message")
    }
    var image: Image? {
        Image(systemName: "rectangle.dashed")
    }
    var rules: [Rule] {
        #Rule(Self.cycleDismissed) { $0.donations.count > 0 }
    }
}
