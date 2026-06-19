import SwiftUI
import UIKit

/// Bridges the in-app data to `ActivityPDFRenderer`: fetches the App
/// Store download QR + the app logo, renders the PDF, and writes it to a
/// temp file ready for the share sheet. Returns the file URL.
///
/// **Threading.** Marked `@MainActor` so the `UIGraphicsPDFRenderer`
/// drawing (UIKit text layout) runs on the main thread — the safe path
/// per Apple's guidance. The only slow step, QR rasterization, already
/// hops to a background `Task.detached` inside `QRCodeGenerator`, so the
/// main thread is held only for the (fast) page drawing. The caller
/// shows a "Preparing…" state across the await.
@MainActor
enum ActivityPDFExporter {

    /// Render `rows` + `document` to a PDF temp file. `nil` on a write
    /// failure (the caller surfaces an error). The QR encodes the
    /// canonical App Store URL; the logo is the bundled `LogoCircle`.
    static func makeFile(
        rows: [ActivityPDFRow],
        document: ActivityPDFDocument,
        fileName: String,
        displayScale: CGFloat
    ) async -> URL? {
        let qr = await QRCodeGenerator.shared.image(
            for: ApertureWeb.appStore,
            scale: 12,
            displayScale: displayScale
        )
        let logo = UIImage(named: "LogoCircle")
        let data = ActivityPDFRenderer.render(rows: rows, document: document, logo: logo, qr: qr)

        let safeName = sanitize(fileName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            // Replace any stale export of the same name so the share
            // sheet never picks up a previous run's bytes.
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Strip path-hostile characters so the chosen filename is a valid,
    /// single path component (it doubles as the shared document's name).
    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Aperture-Activity.pdf" : cleaned
    }
}

/// Identifiable wrapper so a generated PDF can drive a `.sheet(item:)`.
struct ExportedActivityPDF: Identifiable {
    let id = UUID()
    let url: URL
}

/// Thin `UIActivityViewController` wrapper for sharing the generated PDF.
/// The user drives every destination choice inside the system sheet — the
/// app only hands over a local file URL, it never sends anything itself.
struct ActivityPDFShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
