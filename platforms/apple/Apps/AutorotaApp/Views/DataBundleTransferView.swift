import SwiftUI
import AutorotaKit
import UniformTypeIdentifiers

/// One choice in a page's export menu: a label plus the bundle sections it
/// carries.
struct DataBundleExportOption: Identifiable {
    let title: String
    let systemImage: String
    let sections: FfiBundleSections

    var id: String { title }
}

extension FfiBundleSections {
    /// Everything managed on the Employees page: employees (with weekly
    /// availability) and their date-specific availability exceptions.
    static let employeePage = FfiBundleSections(
        roles: false, employees: true, employeeExceptions: true,
        shiftTemplates: false, shiftExceptions: false
    )

    /// Everything managed on the Shifts page: roles, shift templates, and
    /// date-specific shift changes.
    static let shiftPage = FfiBundleSections(
        roles: true, employees: false, employeeExceptions: false,
        shiftTemplates: true, shiftExceptions: true
    )

    static let employeesOnly = FfiBundleSections(
        roles: false, employees: true, employeeExceptions: false,
        shiftTemplates: false, shiftExceptions: false
    )

    static let employeeExceptionsOnly = FfiBundleSections(
        roles: false, employees: false, employeeExceptions: true,
        shiftTemplates: false, shiftExceptions: false
    )

    static let rolesOnly = FfiBundleSections(
        roles: true, employees: false, employeeExceptions: false,
        shiftTemplates: false, shiftExceptions: false
    )

    static let shiftTemplatesOnly = FfiBundleSections(
        roles: false, employees: false, employeeExceptions: false,
        shiftTemplates: true, shiftExceptions: false
    )

    static let shiftExceptionsOnly = FfiBundleSections(
        roles: false, employees: false, employeeExceptions: false,
        shiftTemplates: false, shiftExceptions: true
    )
}

extension DataBundleExportOption {
    /// Export menu for the Employees page.
    static let employeePageOptions: [DataBundleExportOption] = [
        .init(title: String(localized: "Everything on this page"),
              systemImage: "person.2", sections: .employeePage),
        .init(title: String(localized: "Employees only"),
              systemImage: "person", sections: .employeesOnly),
        .init(title: String(localized: "Availability exceptions only"),
              systemImage: "calendar.badge.exclamationmark", sections: .employeeExceptionsOnly),
    ]

    /// Export menu for the Shifts page.
    static let shiftPageOptions: [DataBundleExportOption] = [
        .init(title: String(localized: "Everything on this page"),
              systemImage: "clock", sections: .shiftPage),
        .init(title: String(localized: "Roles only"),
              systemImage: "tag", sections: .rolesOnly),
        .init(title: String(localized: "Shifts only"),
              systemImage: "clock", sections: .shiftTemplatesOnly),
        .init(title: String(localized: "Shift changes only"),
              systemImage: "calendar.badge.exclamationmark", sections: .shiftExceptionsOnly),
    ]
}

/// Toolbar menu offering JSON bundle export (whole page or per category) and
/// import. Drop into any page's toolbar; pass that page's export options.
struct DataBundleToolbarMenu: View {
    let exportOptions: [DataBundleExportOption]
    let service: AutorotaServiceProtocol
    var onImported: () -> Void = {}

    @State private var isBusy = false
    @State private var error: String?
    @State private var showImport = false
    #if os(iOS)
    @State private var shareURL: URL?
    #endif

    var body: some View {
        Menu {
            Section("Export as JSON") {
                ForEach(exportOptions) { option in
                    Button {
                        Task { await export(option.sections) }
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
            }
            Section {
                Button {
                    showImport = true
                } label: {
                    Label("Import from file…", systemImage: "square.and.arrow.down")
                }
            }
        } label: {
            Label("Import & export data", systemImage: "square.and.arrow.up.on.square")
        }
        .disabled(isBusy)
        .errorAlert($error)
        .sheet(isPresented: $showImport) {
            DataBundleImportView(service: service, onImported: onImported)
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { cleanupShareFile() } }
        )) {
            if let url = shareURL {
                BundleShareSheet(activityItems: [url])
            }
        }
        #endif
    }

    private func export(_ sections: FfiBundleSections) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await service.exportDataBundle(sections: sections)
            #if os(iOS)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("autorota-bundle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(result.filename)
            try result.data.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
            #else
            let panel = NSSavePanel()
            panel.nameFieldStringValue = result.filename
            panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let dest = panel.url {
                try result.data.write(to: dest, atomically: true, encoding: .utf8)
            }
            #endif
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    #if os(iOS)
    private func cleanupShareFile() {
        if let url = shareURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        shareURL = nil
    }
    #endif
}

/// Bundle importer: picks a JSON bundle file, shows what it contains, then
/// applies it. Matching records are updated, new ones inserted; nothing is
/// deleted.
struct DataBundleImportView: View {
    let service: AutorotaServiceProtocol
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var fileData: Data?
    @State private var info: FfiBundleInfo?
    @State private var sourceFilename: String?
    @State private var isBusy = false
    @State private var error: String?
    @State private var summary: FfiBundleImportSummary?

    #if os(iOS)
    @State private var showDocPicker = false
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if let s = summary {
                    summaryView(s)
                } else if let info {
                    confirmView(info)
                } else {
                    pickerView
                }
            }
            .navigationTitle("Import Data")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if info != nil && summary == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if isBusy {
                            ProgressView()
                        } else {
                            Button("Import") { Task { await apply() } }
                        }
                    }
                }
            }
            .errorAlert($error)
            #if os(iOS)
            .sheet(isPresented: $showDocPicker) {
                BundleDocumentPicker { url in Task { await loadFile(url) } }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 380, idealHeight: 480)
        #endif
    }

    private var pickerView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Choose a JSON data file exported from Autorota.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose File…") { pickFile() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func confirmView(_ info: FfiBundleInfo) -> some View {
        List {
            if let name = sourceFilename {
                Section {
                    Text(name).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("This file contains") {
                countRow("Roles", "tag", info.roles)
                countRow("Employees", "person", info.employees)
                countRow("Availability exceptions", "calendar.badge.exclamationmark", info.employeeExceptions)
                countRow("Shifts", "clock", info.shiftTemplates)
                countRow("Shift changes", "calendar.badge.exclamationmark", info.shiftExceptions)
            }
            Section {
                Text("Entries matching an existing name will be updated; new entries will be added. Nothing is deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func countRow(_ label: String, _ icon: String, _ count: UInt32) -> some View {
        if count > 0 {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func summaryView(_ s: FfiBundleImportSummary) -> some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.green)
                        Text("Imported").font(.title3).bold()
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section("Applied") {
                resultRow("Roles added", s.rolesAdded)
                resultRow("Employees added", s.employeesAdded)
                resultRow("Employees updated", s.employeesUpdated)
                resultRow("Availability exceptions", s.employeeExceptionsApplied)
                resultRow("Shifts added", s.shiftTemplatesAdded)
                resultRow("Shifts updated", s.shiftTemplatesUpdated)
                resultRow("Shift changes", s.shiftExceptionsApplied)
            }
            if !s.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(s.warnings, id: \.self) {
                        Text($0).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Button("Done") { onImported(); dismiss() }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ count: UInt32) -> some View {
        if count > 0 {
            HStack {
                Text(label)
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func pickFile() {
        #if os(iOS)
        showDocPicker = true
        #else
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await loadFile(url) }
        }
        #endif
    }

    private func loadFile(_ url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try await service.inspectDataBundle(bytes: data)
            fileData = data
            info = parsed
            sourceFilename = url.lastPathComponent
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func apply() async {
        guard let data = fileData else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            summary = try await service.importDataBundle(bytes: data)
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}

#if os(iOS)
private struct BundleShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct BundleDocumentPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPicked(url)
        }
    }
}
#endif
