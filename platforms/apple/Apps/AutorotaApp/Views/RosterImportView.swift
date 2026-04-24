import SwiftUI
import AutorotaKit
import UniformTypeIdentifiers

/// Roster importer: picks a CSV/JSON/XLSX file, previews parsed rows with a
/// diff against the existing roster, then applies in one transaction.
struct RosterImportView: View {
    let service: AutorotaServiceProtocol
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rows: [FfiParsedEmployeeRow] = []
    @State private var warnings: [String] = []
    @State private var strategy: String = "name"
    @State private var sourceFilename: String?
    @State private var isBusy = false
    @State private var error: String?
    @State private var summary: FfiImportSummary?

    #if os(iOS)
    @State private var showDocPicker = false
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if let s = summary {
                    summaryView(s)
                } else if rows.isEmpty {
                    pickerView
                } else {
                    previewList
                }
            }
            .navigationTitle("Import Employees")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !rows.isEmpty && summary == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if isBusy {
                            ProgressView()
                        } else {
                            Button("Import \(includedCount)") { Task { await apply() } }
                                .disabled(includedCount == 0)
                        }
                    }
                }
            }
            .alert("Import Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            #if os(iOS)
            .sheet(isPresented: $showDocPicker) {
                DocumentPicker { url in Task { await loadFile(url) } }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        #endif
    }

    private var pickerView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Choose a CSV, JSON, or XLSX file to import.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Picker("Merge by", selection: $strategy) {
                Text("Name").tag("name")
                Text("Insert only").tag("insert_only")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)

            Button("Choose File…") { pickFile() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var previewList: some View {
        List {
            if let name = sourceFilename {
                Section {
                    Text(name).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !warnings.isEmpty {
                Section("Warnings") {
                    ForEach(warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                }
            }
            Section("Rows") {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(
                            get: { rows[i].include },
                            set: { rows[i].include = $0 }
                        ))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(rows[i])).font(.headline)
                            Text(rows[i].diffSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func summaryView(_ s: FfiImportSummary) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Imported").font(.title2).bold()
            HStack(spacing: 24) {
                stat("New", s.inserted)
                stat("Updated", s.updated)
                stat("Skipped", s.skipped)
            }
            Button("Done") { onImported(); dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top)
        }
        .padding()
    }

    private func stat(_ label: String, _ n: UInt32) -> some View {
        VStack {
            Text("\(n)").font(.largeTitle).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var includedCount: Int {
        rows.filter { $0.include }.count
    }

    private func displayName(_ r: FfiParsedEmployeeRow) -> String {
        let nick = r.nickname?.trimmingCharacters(in: .whitespaces) ?? ""
        if !nick.isEmpty { return nick }
        return "\(r.firstName) \(r.lastName)".trimmingCharacters(in: .whitespaces)
    }

    private func pickFile() {
        #if os(iOS)
        showDocPicker = true
        #else
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .commaSeparatedText,
            .json,
            UTType(filenameExtension: "xlsx") ?? .data,
        ]
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
            let hint = url.pathExtension.lowercased()
            let result = try await service.parseRosterFile(
                bytes: data,
                formatHint: hint,
                strategy: strategy
            )
            rows = result.rows
            warnings = result.warnings
            sourceFilename = url.lastPathComponent
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func apply() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let toApply = rows.filter { $0.include }
            let result = try await service.applyRosterImport(rows: toApply)
            summary = result
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}

#if os(iOS)
private struct DocumentPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [
            .commaSeparatedText,
            .json,
            UTType(filenameExtension: "xlsx") ?? .data,
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
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
