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
                ],
                examples: [
                    "help.section.employees.example.1",
                    "help.section.employees.example.2",
                    "help.section.employees.example.3",
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
                ],
                examples: [
                    "help.section.shifts.example.1",
                    "help.section.shifts.example.2",
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
                ],
                examples: [
                    "help.section.rota.example.1",
                    "help.section.rota.example.2",
                ]
            )

            helpSection(
                title: "help.section.scheduler",
                icon: "wand.and.stars",
                items: [
                    "help.section.scheduler.item.1",
                    "help.section.scheduler.item.2",
                    "help.section.scheduler.item.3",
                    "help.section.scheduler.item.4",
                ],
                examples: [
                    "help.section.scheduler.example.1",
                    "help.section.scheduler.example.2",
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
                ],
                examples: [
                    "help.section.exceptions.example.1",
                    "help.section.exceptions.example.2",
                ]
            )

            helpSection(
                title: "help.section.history",
                icon: "clock.arrow.circlepath",
                items: [
                    "help.section.history.item.1",
                    "help.section.history.item.2",
                    "help.section.history.item.3",
                ],
                examples: [
                    "help.section.history.example.1",
                    "help.section.history.example.2",
                ]
            )

            helpSection(
                title: "help.section.exporting",
                icon: "square.and.arrow.up",
                items: [
                    "help.section.exporting.item.1",
                    "help.section.exporting.item.2",
                    "help.section.exporting.item.3",
                ],
                examples: [
                    "help.section.exporting.example.1",
                    "help.section.exporting.example.2",
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
                ],
                examples: [
                    "help.section.settings.example.1",
                    "help.section.settings.example.2",
                ]
            )
        }
        .navigationTitle("help.nav_title")
    }

    @ViewBuilder
    private func helpSection(
        title: LocalizedStringKey,
        icon: String,
        items: [LocalizedStringKey],
        examples: [LocalizedStringKey]? = nil
    ) -> some View {
        DisclosureGroup {
            ForEach(items.indices, id: \.self) { idx in
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: "\u{2022}")
                    Text(items[idx])
                }
                .font(.title3)
            }
            if let examples, !examples.isEmpty {
                helpExamples(examples)
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func helpExamples(_ items: [LocalizedStringKey]) -> some View {
        DisclosureGroup {
            ForEach(items.indices, id: \.self) { idx in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    Text(items[idx])
                }
                .font(.body)
                .padding(.vertical, 2)
            }
        } label: {
            Label("help.examples.label", systemImage: "text.book.closed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func helpStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number).")
                .bold()
            Text(text)
        }
    }
}
