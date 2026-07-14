import Foundation
import AutorotaKit

/// Shared temp-dir + payload handling for FFI export results. The core
/// returns binary formats (PDF, XLSX) base64-encoded in `data` and everything
/// else as UTF-8 text.

/// Formats whose FFI payload is base64-encoded binary rather than UTF-8 text.
func exportFormatIsBinary(_ format: String) -> Bool {
    format == "pdf" || format == "xlsx"
}

enum ExportPayloadError: LocalizedError {
    case invalidBinaryPayload
    var errorDescription: String? {
        String(localized: "The export payload could not be decoded.")
    }
}

/// Creates a unique temporary directory (`<prefix>-<uuid>`) for staging
/// export files. Callers are responsible for removing it when done.
func makeExportTempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

extension FfiExportResult {
    /// Whether the payload is base64 binary, judged from the mime type.
    var hasBinaryPayload: Bool {
        mimeType == "application/pdf" || mimeType.contains("spreadsheetml")
    }

    /// Decoded payload bytes. Pass `binary:` explicitly when the caller keys
    /// the decision on its requested format; defaults to the mime-type check.
    func decodedPayload(binary: Bool? = nil) throws -> Data {
        if binary ?? hasBinaryPayload {
            guard let decoded = Data(base64Encoded: data) else {
                throw ExportPayloadError.invalidBinaryPayload
            }
            return decoded
        }
        return Data(data.utf8)
    }

    /// Writes the payload into `dir` under its own filename and returns the
    /// file URL.
    @discardableResult
    func write(into dir: URL, binary: Bool? = nil) throws -> URL {
        let url = dir.appendingPathComponent(filename)
        if binary ?? hasBinaryPayload {
            guard let decoded = Data(base64Encoded: data) else {
                throw ExportPayloadError.invalidBinaryPayload
            }
            try decoded.write(to: url, options: .atomic)
        } else {
            try data.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
