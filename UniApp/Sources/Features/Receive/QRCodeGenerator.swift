import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// QR-code generator + per-payload cache. Wraps Core Image's native
/// `CIFilter.qrCodeGenerator()` — no third-party dependency (Rule #3).
///
/// **Why a cache.** The Receive screen rebuilds its body on every
/// chain switch / size-class change / theme toggle / locale flip. The
/// QR for a given `(chain, address)` doesn't change between rebuilds —
/// regenerating it would burn CPU + a frame of latency for no visible
/// benefit. The cache is keyed by payload string; identical payloads
/// reuse the rendered `UIImage`.
///
/// **Error-correction level.** Set to `"H"` (≈30% recovery) so the
/// small chain-logo overlay at the centre stays scannable even when it
/// obscures up to ~30% of the modules. This is the same level Apple
/// uses for Wallet pass barcodes and what Trust Wallet / Coinbase
/// Wallet ship.
///
/// **Honesty.** The generator is purely deterministic and offline —
/// no network call, no server, no analytics. The payload goes in, the
/// pixel buffer comes out, the image stays on this device.
@MainActor
final class QRCodeGenerator {
    static let shared = QRCodeGenerator()

    private let context = CIContext(options: nil)
    private var cache: [String: UIImage] = [:]
    /// Insertion order of `cache` keys — FIFO eviction removes only
    /// the oldest entry at capacity, not the entire cache.
    private var insertionOrder: [String] = []
    private let maxEntries: Int = 32

    private init() {}

    /// Render the payload to a `UIImage` at the requested output size.
    /// Returns `nil` only when Core Image fails to produce a CIImage
    /// (extremely rare — empty payload, encoding overflow).
    ///
    /// `displayScale` is the rendering context's screen scale — pass
    /// the call site's `@Environment(\.displayScale)` so the image's
    /// point size is correct for the window it renders in (the
    /// deprecated `UIScreen.main` singleton is wrong on external /
    /// Stage Manager displays). Defaults to 3 (every modern iPhone)
    /// when the caller has no environment available.
    func image(for payload: String, scale: CGFloat = 16, displayScale: CGFloat = 3) -> UIImage? {
        if let hit = cache[payload] { return hit }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"

        guard let output = filter.outputImage else { return nil }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cg = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        let image = UIImage(cgImage: cg, scale: displayScale, orientation: .up)

        // Evict ONLY the oldest entry at capacity — bounded FIFO. The
        // cache is per-process and per-launch, no persistence.
        if cache.count >= maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[payload] = image
        insertionOrder.append(payload)
        return image
    }
}
