import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// QR-code generator + per-payload/style cache. Wraps Core Image's native
/// `CIFilter.qrCodeGenerator()` — no third-party dependency (Rule #3).
///
/// **Why a cache.** The Receive screen rebuilds its body on every
/// chain switch / size-class change / theme toggle / locale flip. The
/// QR for a given `(chain, address, appearance)` doesn't change between
/// rebuilds — regenerating it would burn CPU + a frame of latency for no
/// visible benefit. The cache is keyed by payload string plus style;
/// identical payload/style pairs reuse the rendered `UIImage`.
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

    enum Style: String, Sendable {
        /// Black modules on a transparent background. The receive card
        /// provides the white/light card surface behind it.
        case standard
        /// White modules on a transparent background. Used by dark-mode
        /// receive cards so the QR sits on the app's soft card surface.
        case inverted

        fileprivate var colors: QRCodeStyleColors {
            switch self {
            case .standard:
                return QRCodeStyleColors(
                    module: QRCodeRGBA(red: 0, green: 0, blue: 0, alpha: 1),
                    background: QRCodeRGBA(red: 1, green: 1, blue: 1, alpha: 0)
                )
            case .inverted:
                return QRCodeStyleColors(
                    module: QRCodeRGBA(red: 1, green: 1, blue: 1, alpha: 1),
                    background: QRCodeRGBA(red: 0, green: 0, blue: 0, alpha: 0)
                )
            }
        }
    }

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
    func cachedImage(for payload: String, style: Style = .standard) -> UIImage? {
        cache[cacheKey(for: payload, style: style)]
    }

    /// Return the QR for `payload`, generating it OFF the main thread on a
    /// cache miss (Rule #28 — CIFilter rasterization no longer blocks the
    /// UI when the Receive screen first appears). Cache hits return
    /// instantly. The detached generation uses its OWN `CIContext` (the
    /// non-Sendable shared one is gone) — QR generation is once-per-address
    /// then cached, so a fresh context per miss is cheap.
    func image(
        for payload: String,
        scale: CGFloat = 16,
        displayScale: CGFloat = 3,
        style: Style = .standard
    ) async -> UIImage? {
        let key = cacheKey(for: payload, style: style)
        if let hit = cache[key] { return hit }

        let colors = style.colors

        let generated = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "H"
            guard let output = filter.outputImage else { return nil }

            let palette = CIFilter.falseColor()
            palette.inputImage = output
            palette.color0 = colors.module.ciColor
            palette.color1 = colors.background.ciColor

            guard let styledOutput = palette.outputImage else { return nil }
            let transformed = styledOutput.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
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
        cache[key] = image
        insertionOrder.append(key)
        return image
    }

    /// Render a share/save-ready QR image with the same centred coin mark
    /// the receive screen shows. The raw QR remains cached separately so
    /// the on-screen card stays cheap to rebuild.
    func brandedImage(
        for payload: String,
        chain: SupportedChain,
        tokenSymbol: String? = nil,
        scale: CGFloat = 16,
        displayScale: CGFloat = 3
    ) async -> UIImage? {
        guard let qr = await image(for: payload, scale: scale, displayScale: displayScale) else {
            return nil
        }
        return Self.composeBrandedQRCode(
            qr: qr,
            chain: chain,
            symbol: tokenSymbol ?? chain.ticker,
            displayScale: displayScale
        )
    }

    static func composeBrandedQRCode(
        qr: UIImage,
        chain: SupportedChain,
        symbol: String,
        displayScale: CGFloat = 3
    ) -> UIImage {
        let side = max(qr.size.width, qr.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = true

        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let qrRect = CGRect(
                x: (side - qr.size.width) / 2,
                y: (side - qr.size.height) / 2,
                width: qr.size.width,
                height: qr.size.height
            )
            qr.draw(in: qrRect)

            let plateSide = side * 0.18
            let logoSide = plateSide * 0.74
            let plateRect = CGRect(
                x: (side - plateSide) / 2,
                y: (side - plateSide) / 2,
                width: plateSide,
                height: plateSide
            )
            let logoRect = CGRect(
                x: (side - logoSide) / 2,
                y: (side - logoSide) / 2,
                width: logoSide,
                height: logoSide
            )

            let platePath = UIBezierPath(roundedRect: plateRect, cornerRadius: plateSide * 0.22)
            UIColor.white.setFill()
            platePath.fill()

            if let logo = logoImage(chain: chain, symbol: symbol) {
                context.cgContext.saveGState()
                UIBezierPath(ovalIn: logoRect).addClip()
                logo.draw(in: logoRect)
                context.cgContext.restoreGState()
            } else {
                let color = UIColor(AssetLogoSource.brandColor(symbol: symbol, chain: chain))
                color.setFill()
                UIBezierPath(ovalIn: logoRect).fill()

                let initials = String(symbol.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3)).uppercased()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: logoSide * 0.34, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let text = initials.isEmpty ? "-" : initials
                let textSize = text.size(withAttributes: attributes)
                text.draw(
                    at: CGPoint(
                        x: logoRect.midX - textSize.width / 2,
                        y: logoRect.midY - textSize.height / 2
                    ),
                    withAttributes: attributes
                )
            }
        }
    }

    private static func logoImage(chain: SupportedChain, symbol: String) -> UIImage? {
        if let networkName = chain.logoAssetName, let image = UIImage(named: networkName) {
            return image
        }
        if let stablecoin = AssetLogoSource.stablecoinAssetName(symbol: symbol),
           let image = UIImage(named: stablecoin) {
            return image
        }
        if let nativeName = AssetLogoSource.nativeTokenAssetName(symbol: symbol),
           let image = UIImage(named: nativeName) {
            return image
        }
        if let url = AssetLogoSource.stablecoinLogoURL(symbol: symbol),
           let image = AssetLogoDiskCache.shared.image(for: url) {
            return image
        }
        if let url = AssetLogoSource.networkLogoURL(chain: chain),
           let image = AssetLogoDiskCache.shared.image(for: url) {
            return image
        }
        return nil
    }

    private func cacheKey(for payload: String, style: Style) -> String {
        "\(style.rawValue)|\(payload)"
    }
}

private struct QRCodeStyleColors: Sendable {
    let module: QRCodeRGBA
    let background: QRCodeRGBA
}

private struct QRCodeRGBA: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var ciColor: CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
