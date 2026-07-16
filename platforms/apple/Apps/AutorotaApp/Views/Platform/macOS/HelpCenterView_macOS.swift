#if os(macOS)
import SwiftUI

struct HelpCenterView: View {
    var body: some View {
        HelpCenterContent()
            .formStyle(.grouped)
    }
}
#endif
