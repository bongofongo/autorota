import SwiftUI
import PDFKit
import AutorotaKit

/// Preview sheet shown from the Export Settings tab. Renders a PDF generated
/// from synthetic fixture data so the user can see how the current settings
/// will look before committing to a real export. Regenerated only on
/// present — close and re-open to re-render after changing settings.
struct ExportPreviewSheet: View {
    enum Scope: String {
        case full
        case employee

        var title: String {
            switch self {
            case .full: "Full View Preview"
            case .employee: "Employee View Preview"
            }
        }
    }

    let scope: Scope
    let service: AutorotaServiceProtocol

    // Full View defaults
    @AppStorage("exportDefaultLayout") private var fullLayout: String = "employee_by_weekday"

    // Employee exports have a fixed shape: shift name + times, never wages.
    private let empProfile = "staff_schedule"

    @Environment(\.dismiss) private var dismiss

    @State private var pdfData: Data?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let pdfData {
                    PDFPreview(data: pdfData)
                        .ignoresSafeArea(edges: .bottom)
                } else if let error {
                    ContentUnavailableView(
                        "Preview failed",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(error)
                    )
                } else {
                    ProgressView("Generating preview…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(scope.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await generate() }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 680, minHeight: 520, idealHeight: 760)
        #endif
    }

    private func generate() async {
        do {
            let result: FfiExportResult
            switch scope {
            case .full:
                let cfg = FullExportConfigBuilder.make(
                    layoutPref: fullLayout,
                    format: "pdf"
                )
                result = try await service.exportPreviewFull(config: cfg)
            case .employee:
                let cfg = FfiEmployeeExportConfig(
                    employeeId: 0,
                    startDate: "2099-04-20",
                    endDate: "2099-04-26",
                    format: "pdf",
                    profile: empProfile,
                    showShiftName: true,
                    showTimes: true,
                    showRole: false,
                    timezoneId: TimeZone.current.identifier
                )
                result = try await service.exportPreviewEmployee(config: cfg)
            }

            guard let decoded = Data(base64Encoded: result.data) else {
                error = "Failed to decode PDF payload."
                return
            }
            pdfData = decoded
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}

#if os(iOS)
private struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(data: data)
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.dataRepresentation() != data {
            uiView.document = PDFDocument(data: data)
        }
    }
}
#else
private struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(data: data)
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.dataRepresentation() != data {
            nsView.document = PDFDocument(data: data)
        }
    }
}
#endif
