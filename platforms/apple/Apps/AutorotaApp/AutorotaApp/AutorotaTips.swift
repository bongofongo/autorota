import SwiftUI
import TipKit

/// Coach-mark tips surfaced once per install on the rich edit surfaces.
/// Configured globally from `AutorotaAppApp.init()`.

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
}
