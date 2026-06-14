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
    /// Synchronous cache-only lookup (no generation). The Receive card
    /// calls this first so an already-rendered QR shows instantly with no
    /// flash; on a miss it awaits `image(for:)` to generate off-main.
    func cachedImage(for payload: String) -> UIImage? { cache[payload] }

    /// Return the QR for `payload`, generating it OFF the main thread on a
    /// cache miss (Rule #28 — CIFilter rasterization no longer blocks the
    /// UI when the Receive screen first appears). Cache hits return
    /// instantly. The detached generation uses its OWN `CIContext` (the
    /// non-Sendable shared one is gone) — QR generation is once-per-address
    /// then cached, so a fresh context per miss is cheap.
    func image(for payload: String, scale: CGFloat = 16, displayScale: CGFloat = 3) async -> UIImage? {
        if let hit = cache[payload] { return hit }

        let generated = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "H"
            guard let output = filter.outputImage else { return nil }
            let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let context = CIContext(options: nil)
            guard let cg = context.createCGImage(transformed, from: transformed.extent) else {
                return nil
            }
            return UIImage(cgImage: cg, scale: displayScale, orientation: .up)
        }.value

        guard let image = generated else { return nil }

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
