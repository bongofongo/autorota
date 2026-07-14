import SwiftUI
import PDFKit
import QuickLook
import WebKit
import AutorotaKit

#if os(iOS)
import UIKit
#else
import AppKit
import Quartz
#endif

/// Preview surface presented from the Rota tab share pull-up. Routes to a
/// format-specific viewer:
///   pdf       → PDFKit
///   xlsx, ics → QuickLook (file URL)
///   csv, json → monospaced text scroll view
///   markdown  → WKWebView with minimal markdown→HTML conversion
struct RotaExportPreview: View {
    let title: String
    let format: String
    let result: FfiExportResult
    let footnote: String?

    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var setupError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView(
                        "Preview failed",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(setupError)
                    )
                } else {
                    body(for: format)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
        }
        .task { prepareFileIfNeeded() }
        .onDisappear { cleanupFile() }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 720, minHeight: 520, idealHeight: 760)
        #endif
    }

    @ViewBuilder
    private func body(for format: String) -> some View {
        switch format {
        case "pdf":
            if let data = decodedBinary() {
                PDFPreview(data: data).ignoresSafeArea(edges: .bottom)
            } else {
                decodeFailed
            }
        case "xlsx", "ics":
            if let url = fileURL {
                QuickLookPreview(url: url).ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case "csv", "text":
            MonospacedTextPreview(text: result.data)
        case "json":
            MonospacedTextPreview(text: prettyJson(result.data))
        case "markdown":
            MarkdownPreview(source: result.data)
        default:
            ContentUnavailableView(
                "Unsupported format",
                systemImage: "doc",
                description: Text("No preview for .\(format)")
            )
        }
    }

    private var decodeFailed: some View {
        ContentUnavailableView(
            "Preview failed",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Could not decode binary payload.")
        )
    }

    // MARK: - File staging for QuickLook

    private func prepareFileIfNeeded() {
        guard format == "xlsx" || format == "ics", fileURL == nil else { return }
        do {
            let dir = try makeExportTempDir(prefix: "autorota-preview")
            fileURL = try result.write(into: dir, binary: format == "xlsx")
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func cleanupFile() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        self.fileURL = nil
    }

    private func decodedBinary() -> Data? {
        Data(base64Encoded: result.data)
    }

    private func prettyJson(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let str = String(data: pretty, encoding: .utf8)
        else { return raw }
        return str
    }
}

// MARK: - PDFKit

/// Shared PDF preview representable (also used by ExportPreviewSheet).
#if os(iOS)
struct PDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(data: data)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document?.dataRepresentation() != data {
            v.document = PDFDocument(data: data)
        }
    }
}
#else
struct PDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(data: data)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.dataRepresentation() != data {
            v.document = PDFDocument(data: data)
        }
    }
}
#endif

// MARK: - QuickLook

#if os(iOS)
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
#else
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        v.previewItem = url as QLPreviewItem
        v.autostarts = true
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? URL) != url {
            v.previewItem = url as QLPreviewItem
        }
    }
}
#endif

// MARK: - Monospaced text (CSV / JSON)

private struct MonospacedTextPreview: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Markdown (WKWebView)

private struct MarkdownPreview: View {
    let source: String
    var body: some View {
        MarkdownWebView(html: htmlDocument(for: source))
            .ignoresSafeArea(edges: .bottom)
    }
}

#if os(iOS)
private struct MarkdownWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        v.loadHTMLString(html, baseURL: nil)
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: nil)
    }
}
#else
private struct MarkdownWebView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.setValue(false, forKey: "drawsBackground")
        v.loadHTMLString(html, baseURL: nil)
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: nil)
    }
}
#endif

// MARK: - Minimal markdown → HTML

/// Renders the subset of GFM that `export::markdown` produces:
/// ATX headings, GFM tables, unordered bullet lists, `**bold**`, `<br>` passthrough,
/// and blank-line separated paragraphs. Anything more exotic falls through as text.
private func htmlDocument(for source: String) -> String {
    let body = markdownToHtml(source)
    let css = """
    body { font: -apple-system-body; padding: 16px; color: #111; }
    h1 { font-size: 1.5em; margin: 0.6em 0 0.3em; }
    h2 { font-size: 1.25em; margin: 0.6em 0 0.3em; }
    h3 { font-size: 1.1em; margin: 0.5em 0 0.25em; }
    p { margin: 0.4em 0; }
    ul { padding-left: 1.2em; margin: 0.4em 0; }
    li { margin: 0.15em 0; }
    table { border-collapse: collapse; margin: 0.6em 0; width: 100%; }
    th, td { border: 1px solid #d0d0d0; padding: 6px 10px; text-align: left;
             font-size: 0.92em; vertical-align: top; }
    th { background: #f3f3f3; font-weight: 600; }
    tr:nth-child(even) td { background: #fafafa; }
    @media (prefers-color-scheme: dark) {
      body { color: #eee; }
      th, td { border-color: #3a3a3a; }
      th { background: #2a2a2a; }
      tr:nth-child(even) td { background: #1c1c1c; }
    }
    """
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>\(css)</style></head><body>\(body)</body></html>
    """
}

private func markdownToHtml(_ source: String) -> String {
    var out: [String] = []
    let lines = source.components(separatedBy: "\n")
    var i = 0

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            i += 1
            continue
        }

        // Heading
        if let h = parseHeading(trimmed) {
            out.append("<h\(h.level)>\(inlineHtml(h.text))</h\(h.level)>")
            i += 1
            continue
        }

        // Table: header line + separator on next line
        if isTableRow(trimmed), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            let headerCells = splitTableRow(trimmed)
            i += 2
            var bodyRows: [[String]] = []
            while i < lines.count, isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                bodyRows.append(splitTableRow(lines[i].trimmingCharacters(in: .whitespaces)))
                i += 1
            }
            out.append(renderTable(header: headerCells, rows: bodyRows))
            continue
        }

        // Bullet list
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            var items: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") || t.hasPrefix("* ") {
                    items.append(inlineHtml(String(t.dropFirst(2))))
                    i += 1
                } else { break }
            }
            out.append("<ul>" + items.map { "<li>\($0)</li>" }.joined() + "</ul>")
            continue
        }

        // Paragraph: fold consecutive non-empty lines
        var paraLines: [String] = [trimmed]
        i += 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || isTableRow(t) || parseHeading(t) != nil
                || t.hasPrefix("- ") || t.hasPrefix("* ") { break }
            paraLines.append(t)
            i += 1
        }
        out.append("<p>\(inlineHtml(paraLines.joined(separator: " ")))</p>")
    }

    return out.joined(separator: "\n")
}

private func parseHeading(_ line: String) -> (level: Int, text: String)? {
    var level = 0
    for ch in line {
        if ch == "#" { level += 1 } else { break }
    }
    guard level >= 1, level <= 6 else { return nil }
    let rest = line.dropFirst(level)
    guard rest.first == " " else { return nil }
    return (level, String(rest.dropFirst()))
}

private func isTableRow(_ line: String) -> Bool {
    line.hasPrefix("|") && line.hasSuffix("|") && line.count >= 2
}

private func isTableSeparator(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard isTableRow(t) else { return false }
    let cells = splitTableRow(t)
    return !cells.isEmpty && cells.allSatisfy { c in
        let s = c.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        return s.allSatisfy { $0 == "-" || $0 == ":" }
    }
}

private func splitTableRow(_ line: String) -> [String] {
    let inner = line.dropFirst().dropLast()
    return inner.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func renderTable(header: [String], rows: [[String]]) -> String {
    var s = "<table><thead><tr>"
    for h in header { s += "<th>\(inlineHtml(h))</th>" }
    s += "</tr></thead><tbody>"
    for row in rows {
        s += "<tr>"
        for i in 0..<header.count {
            let cell = i < row.count ? row[i] : ""
            s += "<td>\(inlineHtml(cell))</td>"
        }
        s += "</tr>"
    }
    s += "</tbody></table>"
    return s
}

/// Escape HTML, then re-apply `**bold**` and pass through `<br>` tags emitted by
/// the Rust markdown renderer.
private func inlineHtml(_ raw: String) -> String {
    var s = raw
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    s = s.replacingOccurrences(of: "&lt;br&gt;", with: "<br>")
    s = s.replacingOccurrences(of: "&lt;br/&gt;", with: "<br>")
    s = applyBold(s)
    return s
}

private func applyBold(_ s: String) -> String {
    var result = ""
    var rest = Substring(s)
    while let open = rest.range(of: "**") {
        result += rest[..<open.lowerBound]
        let after = rest[open.upperBound...]
        if let close = after.range(of: "**") {
            result += "<strong>" + after[..<close.lowerBound] + "</strong>"
            rest = after[close.upperBound...]
        } else {
            result += "**" + after
            return result
        }
    }
    result += rest
    return result
}
