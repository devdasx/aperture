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
        let assets = await renderAssets(rows: rows, document: document, logo: logo, qr: qr)
        let data = ActivityPDFRenderer.render(rows: rows, document: document, assets: assets)

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

    /// Render one focused transaction receipt to a PDF temp file. This is
    /// separate from the multi-row activity statement so exporting from a
    /// transaction detail screen does not create a full statement wrapper.
    static func makeTransactionReceiptFile(
        row: ActivityPDFRow,
        document: ActivityPDFDocument,
        fileName: String,
        displayScale: CGFloat
    ) async -> URL? {
        let logo = UIImage(named: "LogoCircle")
        let assets = await renderAssets(rows: [row], document: document, logo: logo, qr: nil)
        let data = ActivityPDFRenderer.render(rows: [row], document: document, assets: assets)

        let safeName = sanitize(fileName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
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

    private static func renderAssets(
        rows: [ActivityPDFRow],
        document: ActivityPDFDocument,
        logo: UIImage?,
        qr: UIImage?
    ) async -> ActivityPDFRenderAssets {
        var coinImages: [ActivityPDFIconKey: UIImage] = [:]
        var networkImages: [SupportedChain: UIImage] = [:]

        let rowChains = Set(rows.map(\.chain))
        let summaryChains = Set(document.chainSummaries.map(\.chain))
        for chain in rowChains.union(summaryChains) {
            if let image = await networkImage(for: chain) {
                networkImages[chain] = image
            }
        }

        var seenKeys = Set<ActivityPDFIconKey>()
        for row in rows {
            let key = ActivityPDFIconKey(
                chain: row.chain,
                symbol: row.assetSymbol,
                contract: row.tokenContract
            )
            guard seenKeys.insert(key).inserted else { continue }
            if let image = await coinImage(chain: row.chain, symbol: row.assetSymbol, contract: row.tokenContract) {
                coinImages[key] = image
            }
        }

        return ActivityPDFRenderAssets(
            logo: logo,
            qr: qr,
            coinImages: coinImages,
            networkImages: networkImages
        )
    }

    private static func coinImage(chain: SupportedChain, symbol: String, contract: String?) async -> UIImage? {
        if let url = coinLogoURL(chain: chain, symbol: symbol, contract: contract),
           let image = await image(from: url) {
            return image
        }
        if let localName = localCoinAssetName(chain: chain, symbol: symbol, contract: contract),
           let image = UIImage(named: localName) {
            return image
        }
        if let fallbackName = AssetLogoSource.nativeTokenAssetName(symbol: symbol),
           let image = UIImage(named: fallbackName) {
            return image
        }
        return nil
    }

    private static func networkImage(for chain: SupportedChain) async -> UIImage? {
        if let url = AssetLogoSource.networkLogoURL(chain: chain),
           let image = await image(from: url) {
            return image
        }
        if let localName = chain.logoAssetName, let image = UIImage(named: localName) {
            return image
        }
        if let nativeName = AssetLogoSource.nativeTokenAssetName(symbol: chain.ticker),
           let image = UIImage(named: nativeName) {
            return image
        }
        return nil
    }

    private static func localCoinAssetName(chain: SupportedChain, symbol: String, contract: String?) -> String? {
        let isNative = contract?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && symbol.uppercased() == chain.ticker.uppercased()
        if isNative {
            if let networkName = chain.logoAssetName, UIImage(named: networkName) != nil {
                return networkName
            }
            return AssetLogoSource.nativeTokenAssetName(symbol: symbol)
        }
        if let stablecoin = AssetLogoSource.stablecoinAssetName(symbol: symbol) {
            return stablecoin
        }
        return AssetLogoSource.nativeTokenAssetName(symbol: symbol)
    }

    private static func coinLogoURL(chain: SupportedChain, symbol: String, contract: String?) -> URL? {
        if let contract, !contract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trustWalletURL(AssetLogoSource.tokenLogoURL(chain: chain, contract: contract))
        }
        if let stablecoinURL = trustWalletURL(AssetLogoSource.stablecoinLogoURL(symbol: symbol)) {
            return stablecoinURL
        }
        return trustWalletURL(AssetLogoSource.networkLogoURL(chain: chain))
    }

    private static func trustWalletURL(_ url: URL?) -> URL? {
        guard let url,
              url.host?.localizedCaseInsensitiveContains("trustwallet.com") == true else {
            return nil
        }
        return url
    }

    private static func image(from url: URL) async -> UIImage? {
        if let cached = AssetLogoDiskCache.shared.image(for: url) {
            return cached
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }
            AssetLogoDiskCache.shared.store(image, for: url)
            return image
        } catch {
            return nil
        }
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
