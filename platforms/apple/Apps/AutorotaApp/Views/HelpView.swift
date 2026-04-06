import SwiftUI

struct HelpView: View {
    var body: some View {
        List {
            Section {
                Text("Autorota helps you create weekly shift schedules for your cafe. Follow these steps to get started:")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 8) {
                    helpStep(number: 1, text: "Add your employees and their roles")
                    helpStep(number: 2, text: "Create shift templates for each day")
                    helpStep(number: 3, text: "Generate a rota for any week")
                }
                .font(.title3)
                .padding(.vertical, 4)
            } header: {
                Text("Getting Started")
            }

            helpSection(
                title: "Employees",
                icon: "person.2",
                items: [
                    "Tap the + button to add a new employee.",
                    "Set their first name, last name, and optional nickname.",
                    "Assign one or more roles (e.g. Barista, Kitchen).",
                    "Set an hourly rate and weekly hour limits.",
                    "Mark which hours of each day they are available to work.",
                    "Tap an employee to see their details or shift history.",
                ]
            )

            helpSection(
                title: "Shift Templates",
                icon: "clock",
                items: [
                    "Templates define the shifts you use each week.",
                    "Set a name, start time, end time, and day of the week.",
                    "Choose which roles are needed and how many staff.",
                    "Templates are reused every time you generate a rota.",
                ]
            )

            helpSection(
                title: "Rota",
                icon: "calendar",
                items: [
                    "The main schedule view shows one week at a time.",
                    "Use the arrow buttons to move between weeks.",
                    "Tap Generate to automatically assign employees to shifts.",
                    "Tap any assignment to change it manually.",
                    "Confirm shifts when you are happy with the schedule.",
                ]
            )

            helpSection(
                title: "Overrides",
                icon: "exclamationmark.circle",
                items: [
                    "Use overrides for one-off changes to a specific date.",
                    "Pin an employee to a shift or exclude them from one.",
                    "Override an employee's availability for a single day.",
                    "Overrides take priority over the generated schedule.",
                ]
            )

            helpSection(
                title: "History",
                icon: "clock.arrow.circlepath",
                items: [
                    "View a log of all committed schedule changes.",
                    "See what was changed and when.",
                    "Useful for tracking edits over time.",
                ]
            )

            helpSection(
                title: "Exporting",
                icon: "square.and.arrow.up",
                items: [
                    "Export your rota as CSV or JSON from the Rota tab.",
                    "Choose a layout: by employee or by shift.",
                    "Set your default export preferences in Menu settings.",
                ]
            )

            helpSection(
                title: "Settings",
                icon: "gearshape",
                items: [
                    "Change the app theme to Light, Dark, or System.",
                    "Set your preferred currency for hourly rates.",
                    "Customise which tabs appear in your tab bar.",
                    "iCloud Sync keeps your data up to date across devices.",
                ]
            )
        }
        .navigationTitle("Help & Guide")
    }

    @ViewBuilder
    private func helpSection(title: String, icon: String, items: [String]) -> some View {
        DisclosureGroup {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}")
                    Text(item)
                }
                .font(.title3)
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
        }
    }

    private func helpStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .bold()
            Text(text)
        }
    }
}
