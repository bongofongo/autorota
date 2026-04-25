import SwiftUI

struct HelpView: View {
    var body: some View {
        List {
            Section {
                Text("help.intro")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 8) {
                    helpStep(number: 1, text: "help.step.1")
                    helpStep(number: 2, text: "help.step.2")
                    helpStep(number: 3, text: "help.step.3")
                }
                .font(.title3)
                .padding(.vertical, 4)
            } header: {
                Text("help.section.getting_started")
            }

            helpSection(
                title: "help.section.employees",
                icon: "person.2",
                items: [
                    "help.section.employees.item.1",
                    "help.section.employees.item.2",
                    "help.section.employees.item.3",
                    "help.section.employees.item.4",
                    "help.section.employees.item.5",
                    "help.section.employees.item.6",
                ]
            )

            helpSection(
                title: "help.section.shifts",
                icon: "clock",
                items: [
                    "help.section.shifts.item.1",
                    "help.section.shifts.item.2",
                    "help.section.shifts.item.3",
                    "help.section.shifts.item.4",
                ]
            )

            helpSection(
                title: "help.section.rota",
                icon: "calendar",
                items: [
                    "help.section.rota.item.1",
                    "help.section.rota.item.2",
                    "help.section.rota.item.3",
                    "help.section.rota.item.4",
                    "help.section.rota.item.5",
                ]
            )

            helpSection(
                title: "help.section.exceptions",
                icon: "exclamationmark.circle",
                items: [
                    "help.section.exceptions.item.1",
                    "help.section.exceptions.item.2",
                    "help.section.exceptions.item.3",
                    "help.section.exceptions.item.4",
                ]
            )

            helpSection(
                title: "help.section.history",
                icon: "clock.arrow.circlepath",
                items: [
                    "help.section.history.item.1",
                    "help.section.history.item.2",
                    "help.section.history.item.3",
                ]
            )

            helpSection(
                title: "help.section.exporting",
                icon: "square.and.arrow.up",
                items: [
                    "help.section.exporting.item.1",
                    "help.section.exporting.item.2",
                    "help.section.exporting.item.3",
                ]
            )

            helpSection(
                title: "help.section.settings",
                icon: "gearshape",
                items: [
                    "help.section.settings.item.1",
                    "help.section.settings.item.2",
                    "help.section.settings.item.3",
                    "help.section.settings.item.4",
                ]
            )
        }
        .navigationTitle("help.nav_title")
    }

    @ViewBuilder
    private func helpSection(
        title: LocalizedStringKey,
        icon: String,
        items: [LocalizedStringKey]
    ) -> some View {
        DisclosureGroup {
            ForEach(items.indices, id: \.self) { idx in
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: "\u{2022}")
                    Text(items[idx])
                }
                .font(.title3)
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
        }
    }

    private func helpStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number).")
                .bold()
            Text(text)
        }
    }
}
