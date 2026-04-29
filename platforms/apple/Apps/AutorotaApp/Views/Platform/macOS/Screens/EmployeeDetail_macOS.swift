#if os(macOS)
import SwiftUI
import AutorotaKit

struct EmployeeDetailView: View {
    let employee: FfiEmployee
    let viewModel: EmployeeViewModel

    var body: some View {
        EmployeeDetailContent(employee: employee, viewModel: viewModel)
    }
}
#endif
