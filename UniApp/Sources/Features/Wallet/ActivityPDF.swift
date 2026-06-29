import UIKit

// MARK: - Value model

struct ActivityPDFRow {
    let occurredAt: Date
    let dateText: String
    let timeText: String
    let assetSymbol: String
    let networkName: String
    let chain: SupportedChain
    let tokenContract: String?
    let typeText: String
    let transferType: TransferType
    let amountText: String
    let unitText: String
    let fiatText: String
    let fiatValue: Decimal?
    let statusText: String
    let status: Status

    enum TransferType {
        case received
        case sent
        case internalTransfer
    }

    enum Status {
        case confirmed
        case pending
        case failed
    }
}

struct ActivityPDFChainSummary {
    let chain: SupportedChain
    let count: Int
}

struct ActivityPDFDocument {
    enum Style {
        case statement
        case transactionReceipt
    }

    let appName: String
    let title: String
    let walletName: String
    let generatedText: String
    let transactionCount: Int
    let assetCount: Int
    let confirmedCount: Int
    let failedCount: Int
    let internalCount: Int
    let receivedFiatText: String
    let sentFiatText: String
    let netFiatText: String
    let netIsPositive: Bool
    let periodText: String
    let chainSummaries: [ActivityPDFChainSummary]
    let downloadCaption: String
    let appStoreURLText: String
    let footerSiteText: String
    let pageLabelFormat: String
    let emptyText: String
    let legalTitle: String
    let legalText: String
    let isRTL: Bool
    let style: Style
    let receiptDetails: [ActivityPDFReceiptDetail]

    init(
        appName: String,
        title: String,
        walletName: String,
        generatedText: String,
        transactionCount: Int,
        assetCount: Int,
        confirmedCount: Int,
        failedCount: Int,
        internalCount: Int,
        receivedFiatText: String,
        sentFiatText: String,
        netFiatText: String,
        netIsPositive: Bool,
        periodText: String,
        chainSummaries: [ActivityPDFChainSummary],
        downloadCaption: String,
        appStoreURLText: String,
        footerSiteText: String,
        pageLabelFormat: String,
        emptyText: String,
        legalTitle: String,
        legalText: String,
        isRTL: Bool,
        style: Style = .statement,
        receiptDetails: [ActivityPDFReceiptDetail] = []
    ) {
        self.appName = appName
        self.title = title
        self.walletName = walletName
        self.generatedText = generatedText
        self.transactionCount = transactionCount
        self.assetCount = assetCount
        self.confirmedCount = confirmedCount
        self.failedCount = failedCount
        self.internalCount = internalCount
        self.receivedFiatText = receivedFiatText
        self.sentFiatText = sentFiatText
        self.netFiatText = netFiatText
        self.netIsPositive = netIsPositive
        self.periodText = periodText
        self.chainSummaries = chainSummaries
        self.downloadCaption = downloadCaption
        self.appStoreURLText = appStoreURLText
        self.footerSiteText = footerSiteText
        self.pageLabelFormat = pageLabelFormat
        self.emptyText = emptyText
        self.legalTitle = legalTitle
        self.legalText = legalText
        self.isRTL = isRTL
        self.style = style
        self.receiptDetails = receiptDetails
    }
}

struct ActivityPDFReceiptDetail {
    let label: String
    let value: String
    let monospaced: Bool
}

struct ActivityPDFIconKey: Hashable {
    let chain: SupportedChain
    let symbol: String
    let contract: String?

    init(chain: SupportedChain, symbol: String, contract: String?) {
        self.chain = chain
        self.symbol = symbol.uppercased()
        let trimmed = contract?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contract = trimmed?.isEmpty == false ? trimmed?.lowercased() : nil
    }
}

struct ActivityPDFRenderAssets {
    let logo: UIImage?
    let qr: UIImage?
    let coinImages: [ActivityPDFIconKey: UIImage]
    let networkImages: [SupportedChain: UIImage]
}

// MARK: - Renderer

enum ActivityPDFRenderer {
    private static let pageSize = CGSize(width: 794, height: 1123)
    private static let topPadding: CGFloat = 60
    private static let sidePadding: CGFloat = 58
    private static let bottomPadding: CGFloat = 56
    private static let firstPageRows = 9
    private static let continuationRows = 16

    private static var contentWidth: CGFloat { pageSize.width - sidePadding * 2 }
    private static var contentRight: CGFloat { pageSize.width - sidePadding }
    private static var footerRuleY: CGFloat { pageSize.height - bottomPadding - 30 }

    private static let ink = UIColor(hex: 0x0C0D11)
    private static let inkSoft = UIColor(hex: 0x3A3D45)
    private static let sub = UIColor(hex: 0x6A6E78)
    private static let faint = UIColor(hex: 0x9A9EA8)
    private static let hair = UIColor(hex: 0xE9EAEE)
    private static let hair2 = UIColor(hex: 0xF1F2F4)
    private static let bg = UIColor.white
    private static let chip = UIColor(hex: 0xF4F5F7)
    private static let pos = UIColor(hex: 0x178A52)
    private static let warn = UIColor(hex: 0xD97706)
    private static let fail = UIColor(hex: 0xC8472F)
    private static let legalFill = UIColor(hex: 0xFCFCFD)

    private struct Column {
        let x: CGFloat
        let width: CGFloat
        let trailing: Bool
    }

    private static let columns: [Column] = {
        var x = sidePadding
        func next(_ width: CGFloat, trailing: Bool = false) -> Column {
            let column = Column(x: x, width: width, trailing: trailing)
            x += width
            return column
        }
        return [
            next(96),
            next(182),
            next(92),
            next(128, trailing: true),
            next(76, trailing: true),
            next(104, trailing: true)
        ]
    }()

    static func render(
        rows: [ActivityPDFRow],
        document: ActivityPDFDocument,
        assets: ActivityPDFRenderAssets
    ) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(document.appName) - \(document.title)",
            kCGPDFContextCreator as String: document.appName
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        if document.style == .transactionReceipt, let row = rows.first {
            return renderer.pdfData { context in
                context.beginPage()
                fill(CGRect(origin: .zero, size: pageSize), color: bg)
                drawTransactionReceipt(row: row, document: document, assets: assets)
            }
        }

        let chunks = pageChunks(rows)
        let totalPages = max(1, chunks.count)

        return renderer.pdfData { context in
            for index in chunks.indices {
                context.beginPage()
                fill(CGRect(origin: .zero, size: pageSize), color: bg)
                let pageNumber = index + 1
                let top = index == 0
                    ? drawFirstPageHeader(document: document, assets: assets)
                    : drawRunningHeader(document: document, assets: assets)

                drawTable(
                    rows: chunks[index],
                    at: top,
                    document: document,
                    assets: assets
                )

                if pageNumber == totalPages {
                    drawLegal(document: document)
                }
                drawFooter(document: document, page: pageNumber, total: totalPages, logo: assets.logo)
            }
        }
    }

    private static func pageChunks(_ rows: [ActivityPDFRow]) -> [[ActivityPDFRow]] {
        guard !rows.isEmpty else { return [[]] }
        var chunks: [[ActivityPDFRow]] = []
        chunks.append(Array(rows.prefix(firstPageRows)))
        var cursor = min(firstPageRows, rows.count)
        while cursor < rows.count {
            let end = min(cursor + continuationRows, rows.count)
            chunks.append(Array(rows[cursor..<end]))
            cursor = end
        }
        return chunks
    }

    // MARK: - Single transaction receipt

    private static func drawTransactionReceipt(
        row: ActivityPDFRow,
        document: ActivityPDFDocument,
        assets: ActivityPDFRenderAssets
    ) {
        drawReceiptHeader(document: document, logo: assets.logo)

        let card = CGRect(x: sidePadding, y: 178, width: contentWidth, height: 308)
        fillRounded(card, radius: 28, color: UIColor(hex: 0xFBFCFE))
        strokeRounded(card, radius: 28, color: hair, lineWidth: 1)

        let key = ActivityPDFIconKey(chain: row.chain, symbol: row.assetSymbol, contract: row.tokenContract)
        let coinRect = CGRect(x: card.midX - 34, y: card.minY + 34, width: 68, height: 68)
        if let image = assets.coinImages[key] {
            drawCircleImage(image, in: coinRect)
        } else {
            drawMonogram(row.assetSymbol, in: coinRect)
        }

        drawText(
            row.typeText.uppercased(),
            in: CGRect(x: card.minX + 40, y: coinRect.maxY + 22, width: card.width - 80, height: 15),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: faint,
            alignment: .center,
            kern: 1.2
        )
        drawText(
            "\(row.amountText) \(row.unitText)",
            in: CGRect(x: card.minX + 38, y: coinRect.maxY + 45, width: card.width - 76, height: 50),
            font: .monospacedDigitSystemFont(ofSize: 35, weight: .semibold),
            color: amountColor(for: row),
            alignment: .center,
            kern: -0.7
        )
        drawText(
            row.fiatText,
            in: CGRect(x: card.minX + 38, y: coinRect.maxY + 96, width: card.width - 76, height: 24),
            font: .monospacedDigitSystemFont(ofSize: 17, weight: .medium),
            color: sub,
            alignment: .center
        )
        drawReceiptStatus(row, centerX: card.midX, y: coinRect.maxY + 134)

        let metaTop = card.maxY + 34
        drawText(
            "DETAILS",
            in: CGRect(x: sidePadding, y: metaTop, width: contentWidth, height: 14),
            font: .systemFont(ofSize: 11, weight: .bold),
            color: faint,
            kern: 1.5
        )

        let details = CGRect(x: sidePadding, y: metaTop + 30, width: contentWidth, height: 348)
        fillRounded(details, radius: 22, color: UIColor(hex: 0xFBFCFE))
        strokeRounded(details, radius: 22, color: hair, lineWidth: 1)

        let rowHeight: CGFloat = 52
        let detailRows = document.receiptDetails.prefix(6)
        for (index, detail) in detailRows.enumerated() {
            let y = details.minY + CGFloat(index) * rowHeight
            if index > 0 {
                fill(CGRect(x: details.minX + 20, y: y, width: details.width - 40, height: 1), color: hair2)
            }
            drawText(
                detail.label,
                in: CGRect(x: details.minX + 24, y: y + 18, width: 160, height: 18),
                font: .systemFont(ofSize: 13, weight: .regular),
                color: sub
            )
            drawText(
                detail.value,
                in: CGRect(x: details.minX + 194, y: y + 17, width: details.width - 218, height: 20),
                font: detail.monospaced
                    ? .monospacedDigitSystemFont(ofSize: 13.5, weight: .medium)
                    : .systemFont(ofSize: 13.5, weight: .medium),
                color: detail.label == "Status" ? statusColor(for: row.status) : inkSoft,
                alignment: .right
            )
        }

        drawReceiptFooter(document: document, logo: assets.logo)
    }

    private static func drawReceiptHeader(document: ActivityPDFDocument, logo: UIImage?) {
        let logoRect = CGRect(x: sidePadding, y: topPadding, width: 42, height: 42)
        if let logo {
            drawRoundedImage(logo, in: logoRect, radius: 12)
        } else {
            drawLogoFallback(in: logoRect, radius: 12)
        }
        drawText(
            document.appName,
            in: CGRect(x: sidePadding + 55, y: topPadding - 1, width: 230, height: 28),
            font: .systemFont(ofSize: 23, weight: .semibold),
            color: ink,
            kern: -0.46
        )
        drawText(
            document.title.uppercased(),
            in: CGRect(x: sidePadding + 55, y: topPadding + 29, width: 260, height: 15),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: sub,
            kern: 2.2
        )
        drawText(
            document.walletName,
            in: CGRect(x: contentRight - 255, y: topPadding + 3, width: 255, height: 22),
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: inkSoft,
            alignment: .right,
            kern: -0.2
        )
        drawText(
            "Generated \(document.generatedText)",
            in: CGRect(x: contentRight - 285, y: topPadding + 29, width: 285, height: 16),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: faint,
            alignment: .right
        )
        fill(CGRect(x: sidePadding, y: topPadding + 72, width: contentWidth, height: 1.5), color: ink)
    }

    private static func drawReceiptStatus(_ row: ActivityPDFRow, centerX: CGFloat, y: CGFloat) {
        let color = statusColor(for: row.status)
        let fillColor = color.withAlphaComponent(0.12)
        let font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let width = max(textWidth(row.statusText, font: font) + 42, 108)
        let rect = CGRect(x: centerX - width / 2, y: y, width: width, height: 30)
        fillRounded(rect, radius: 15, color: fillColor)
        fillOval(CGRect(x: rect.minX + 13, y: rect.midY - 3, width: 6, height: 6), color: color)
        drawText(
            row.statusText,
            in: CGRect(x: rect.minX + 27, y: rect.minY + 7, width: rect.width - 38, height: 16),
            font: font,
            color: color
        )
    }

    private static func drawReceiptFooter(document: ActivityPDFDocument, logo: UIImage?) {
        fill(CGRect(x: sidePadding, y: footerRuleY, width: contentWidth, height: 1), color: hair)
        if let logo {
            drawRoundedImage(logo, in: CGRect(x: sidePadding, y: footerRuleY + 17, width: 18, height: 18), radius: 5)
        } else {
            drawLogoFallback(in: CGRect(x: sidePadding, y: footerRuleY + 17, width: 18, height: 18), radius: 5)
        }
        drawText(
            document.footerSiteText,
            in: CGRect(x: sidePadding + 25, y: footerRuleY + 18, width: 160, height: 14),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: faint
        )
        drawText(
            "\(document.walletName) · Transaction Receipt",
            in: CGRect(x: sidePadding + 210, y: footerRuleY + 18, width: contentWidth - 420, height: 14),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: faint,
            alignment: .center
        )
        drawText(
            "Page 1 of 1",
            in: CGRect(x: contentRight - 90, y: footerRuleY + 18, width: 90, height: 14),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: faint,
            alignment: .right
        )
    }

    // MARK: - Headers

    private static func drawFirstPageHeader(
        document: ActivityPDFDocument,
        assets: ActivityPDFRenderAssets
    ) -> CGFloat {
        let mastTop = topPadding
        let mastBottom = mastTop + 86

        if let logo = assets.logo {
            drawRoundedImage(logo, in: CGRect(x: sidePadding, y: mastTop, width: 42, height: 42), radius: 12)
        } else {
            drawLogoFallback(in: CGRect(x: sidePadding, y: mastTop, width: 42, height: 42), radius: 12)
        }

        drawText(
            document.appName,
            in: CGRect(x: sidePadding + 55, y: mastTop - 1, width: 250, height: 30),
            font: .systemFont(ofSize: 24, weight: .semibold),
            color: ink,
            kern: -0.48
        )
        drawText(
            document.title.uppercased(),
            in: CGRect(x: sidePadding + 55, y: mastTop + 30, width: 260, height: 15),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: sub,
            kern: 2.42
        )

        let qrGroupX = contentRight - 201
        let qrBox = CGRect(x: qrGroupX, y: mastTop, width: 60, height: 60)
        fillRounded(qrBox, radius: 10, color: .white)
        strokeRounded(qrBox, radius: 10, color: hair, lineWidth: 1)
        if let qr = assets.qr {
            qr.draw(in: qrBox.insetBy(dx: 6, dy: 6))
        }
        let capX = qrBox.maxX + 13
        drawText(
            document.downloadCaption,
            in: CGRect(x: capX, y: mastTop + 6, width: 128, height: 17),
            font: .systemFont(ofSize: 12.5, weight: .semibold),
            color: ink
        )
        drawText(
            document.appStoreURLText,
            in: CGRect(x: capX, y: mastTop + 26, width: 128, height: 34),
            font: .systemFont(ofSize: 10, weight: .regular),
            color: faint,
            lineHeight: 14
        )

        fill(CGRect(x: sidePadding, y: mastBottom, width: contentWidth, height: 1.5), color: ink)

        let summaryTop = mastBottom + 26
        drawText(
            document.walletName,
            in: CGRect(x: sidePadding, y: summaryTop, width: 420, height: 32),
            font: .systemFont(ofSize: 27, weight: .bold),
            color: ink,
            kern: -0.81
        )
        drawGeneratedLine(document: document, y: summaryTop + 39)

        drawText(
            "STATEMENT PERIOD",
            in: CGRect(x: contentRight - 260, y: summaryTop + 5, width: 260, height: 14),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: faint,
            alignment: .right,
            kern: 1.1
        )
        drawText(
            document.periodText,
            in: CGRect(x: contentRight - 300, y: summaryTop + 25, width: 300, height: 18),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: ink,
            alignment: .right,
            kern: -0.14
        )

        let statsTop = summaryTop + 73
        drawStats(document: document, at: statsTop)
        let ribbonBottom = drawNetworkRibbon(document: document, assets: assets, at: statsTop + 103)
        return ribbonBottom + 18
    }

    private static func drawRunningHeader(
        document: ActivityPDFDocument,
        assets: ActivityPDFRenderAssets
    ) -> CGFloat {
        let top = topPadding
        if let logo = assets.logo {
            drawRoundedImage(logo, in: CGRect(x: sidePadding, y: top, width: 26, height: 26), radius: 8)
        } else {
            drawLogoFallback(in: CGRect(x: sidePadding, y: top, width: 26, height: 26), radius: 8)
        }
        drawText(
            document.appName,
            in: CGRect(x: sidePadding + 36, y: top + 2, width: 86, height: 17),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: ink,
            kern: -0.14
        )
        drawText(
            document.walletName,
            in: CGRect(x: sidePadding + 112, y: top + 4, width: 300, height: 15),
            font: .systemFont(ofSize: 12, weight: .regular),
            color: sub
        )
        drawText(
            document.title.uppercased(),
            in: CGRect(x: contentRight - 240, y: top + 6, width: 240, height: 14),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: faint,
            alignment: .right,
            kern: 0.88
        )
        let ruleY = top + 40
        fill(CGRect(x: sidePadding, y: ruleY, width: contentWidth, height: 1.5), color: ink)
        return ruleY + 24
    }

    private static func drawGeneratedLine(document: ActivityPDFDocument, y: CGFloat) {
        let full = "Generated \(document.generatedText) · \(document.transactionCount) transactions · \(document.assetCount) assets"
        let attributed = NSMutableAttributedString(
            string: full,
            attributes: [
                .font: UIFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: sub
            ]
        )
        for boldPart in [
            document.generatedText,
            "\(document.transactionCount)",
            "\(document.assetCount)"
        ] {
            let range = (full as NSString).range(of: boldPart)
            if range.location != NSNotFound {
                attributed.addAttributes([
                    .font: UIFont.systemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: inkSoft
                ], range: range)
            }
        }
        attributed.draw(in: CGRect(x: sidePadding, y: y, width: 430, height: 17))
    }

    // MARK: - Summary

    private static func drawStats(document: ActivityPDFDocument, at y: CGFloat) {
        let rect = CGRect(x: sidePadding, y: y, width: contentWidth, height: 88)
        strokeRounded(rect, radius: 14, color: hair, lineWidth: 1)
        let cellWidth = contentWidth / 4
        for index in 1..<4 {
            fill(CGRect(x: sidePadding + CGFloat(index) * cellWidth, y: y, width: 1, height: 88), color: hair)
        }

        let entries: [(String, String, UIColor, String)] = [
            ("TRANSACTIONS", "\(document.transactionCount)", ink, "\(document.confirmedCount) confirmed · \(document.failedCount) failed"),
            ("RECEIVED", document.receivedFiatText, pos, "Inflow across all chains"),
            ("SENT", document.sentFiatText, ink, "Outflow across all chains"),
            ("NET FLOW", document.netFiatText, document.netIsPositive ? pos : ink, "\(document.internalCount) internal transfers")
        ]

        for (index, entry) in entries.enumerated() {
            let x = sidePadding + CGFloat(index) * cellWidth
            drawText(
                entry.0,
                in: CGRect(x: x + 18, y: y + 16, width: cellWidth - 36, height: 13),
                font: .systemFont(ofSize: 10.5, weight: .bold),
                color: faint,
                kern: 0.735
            )
            drawText(
                entry.1,
                in: CGRect(x: x + 18, y: y + 39, width: cellWidth - 22, height: 24),
                font: .monospacedDigitSystemFont(ofSize: 20, weight: .bold),
                color: entry.2,
                kern: -0.4
            )
            drawText(
                entry.3,
                in: CGRect(x: x + 18, y: y + 69, width: cellWidth - 34, height: 15),
                font: .systemFont(ofSize: 10.5, weight: .regular),
                color: sub
            )
        }
    }

    private static func drawNetworkRibbon(
        document: ActivityPDFDocument,
        assets: ActivityPDFRenderAssets,
        at y: CGFloat
    ) -> CGFloat {
        var cursorX = sidePadding
        var cursorY = y
        let lineHeight: CGFloat = 26
        drawText(
            "NETWORKS",
            in: CGRect(x: cursorX, y: cursorY + 7, width: 70, height: 12),
            font: .systemFont(ofSize: 10.5, weight: .bold),
            color: faint,
            kern: 0.735
        )
        cursorX += 77

        for summary in document.chainSummaries {
            let name = summary.chain.displayName
            let chipText = "\(name) \(summary.count)"
            let width = min(max(textWidth(chipText, font: .systemFont(ofSize: 11.5, weight: .semibold)) + 40, 64), contentWidth)
            if cursorX + width > contentRight {
                cursorX = sidePadding
                cursorY += lineHeight + 6
            }
            let rect = CGRect(x: cursorX, y: cursorY, width: width, height: lineHeight)
            fillRounded(rect, radius: lineHeight / 2, color: chip)
            if let image = assets.networkImages[summary.chain] {
                drawCircleImage(image, in: CGRect(x: rect.minX + 6, y: rect.minY + 5, width: 16, height: 16))
            } else {
                fillOval(CGRect(x: rect.minX + 11, y: rect.minY + 10, width: 6, height: 6), color: ink.withAlphaComponent(0.55))
            }
            drawNetworkChipText(name: name, count: summary.count, in: rect)
            cursorX += width + 7
        }
        return cursorY + lineHeight
    }

    private static func drawNetworkChipText(name: String, count: Int, in rect: CGRect) {
        let text = "\(name) \(count)"
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: inkSoft
            ]
        )
        let countRange = (text as NSString).range(of: "\(count)", options: .backwards)
        if countRange.location != NSNotFound {
            attributed.addAttributes([
                .foregroundColor: faint,
                .font: UIFont.systemFont(ofSize: 11.5, weight: .semibold)
            ], range: countRange)
        }
        attributed.draw(in: CGRect(x: rect.minX + 29, y: rect.minY + 6, width: rect.width - 36, height: 14))
    }

    // MARK: - Table

    private static func drawTable(
        rows: [ActivityPDFRow],
        at top: CGFloat,
        document: ActivityPDFDocument,
        assets: ActivityPDFRenderAssets
    ) {
        let headerHeight: CGFloat = 21
        let rowHeight: CGFloat = 49
        let labels = ["DATE", "ASSET", "TYPE", "AMOUNT", "VALUE", "STATUS"]

        for (index, column) in columns.enumerated() {
            drawText(
                labels[index],
                in: CGRect(x: column.x, y: top, width: column.width, height: 13),
                font: .systemFont(ofSize: 10, weight: .bold),
                color: faint,
                alignment: .center,
                kern: 0.8
            )
        }
        fill(CGRect(x: sidePadding, y: top + headerHeight - 1, width: contentWidth, height: 1), color: ink)

        if rows.isEmpty {
            drawText(
                document.emptyText,
                in: CGRect(x: sidePadding, y: top + 54, width: contentWidth, height: 20),
                font: .systemFont(ofSize: 12.5, weight: .regular),
                color: faint,
                alignment: .center
            )
            return
        }

        for (index, row) in rows.enumerated() {
            let y = top + headerHeight + CGFloat(index) * rowHeight
            drawRow(row, at: y, height: rowHeight, assets: assets)
            if index < rows.count - 1 {
                fill(CGRect(x: sidePadding, y: y + rowHeight - 1, width: contentWidth, height: 1), color: hair2)
            }
        }
    }

    private static func drawRow(
        _ row: ActivityPDFRow,
        at y: CGFloat,
        height: CGFloat,
        assets: ActivityPDFRenderAssets
    ) {
        drawText(
            row.dateText,
            in: CGRect(x: columns[0].x, y: y + 9, width: columns[0].width, height: 15),
            font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            color: ink,
            alignment: .center
        )
        drawText(
            row.timeText,
            in: CGRect(x: columns[0].x, y: y + 25, width: columns[0].width, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            color: faint,
            alignment: .center
        )

        let assetColumn = columns[1]
        let assetTextWidth = min(
            max(
                textWidth(row.assetSymbol, font: .systemFont(ofSize: 12.5, weight: .semibold)),
                textWidth(row.networkName, font: .systemFont(ofSize: 11, weight: .regular))
            ),
            assetColumn.width - 41
        )
        let assetGroupWidth = min(41 + assetTextWidth, assetColumn.width)
        let assetX = centeredX(width: assetGroupWidth, in: assetColumn)
        let coinRect = CGRect(x: assetX, y: y + 9, width: 30, height: 30)
        let key = ActivityPDFIconKey(chain: row.chain, symbol: row.assetSymbol, contract: row.tokenContract)
        if let image = assets.coinImages[key] {
            drawCircleImage(image, in: coinRect)
        } else {
            drawMonogram(row.assetSymbol, in: coinRect)
        }
        if let badge = assets.networkImages[row.chain] {
            let ringRect = CGRect(x: coinRect.maxX - 4, y: coinRect.maxY - 10, width: 17, height: 17)
            fillOval(ringRect, color: .white)
            drawCircleImage(badge, in: ringRect.insetBy(dx: 1.5, dy: 1.5))
        }

        drawText(
            row.assetSymbol,
            in: CGRect(x: assetX + 41, y: y + 8, width: assetGroupWidth - 41, height: 16),
            font: .systemFont(ofSize: 12.5, weight: .semibold),
            color: ink,
            kern: -0.125
        )
        drawText(
            row.networkName,
            in: CGRect(x: assetX + 41, y: y + 25, width: assetGroupWidth - 41, height: 13),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: sub
        )

        drawType(row, at: y, height: height)
        drawAmount(row, at: y)
        drawText(
            row.fiatText,
            in: CGRect(x: columns[4].x, y: y + 17, width: columns[4].width, height: 15),
            font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            color: inkSoft,
            alignment: .center
        )
        drawStatus(row, at: y, height: height)
    }

    private static func drawType(_ row: ActivityPDFRow, at y: CGFloat, height: CGFloat) {
        let color: UIColor
        switch row.transferType {
        case .received: color = pos
        case .sent: color = ink
        case .internalTransfer: color = sub
        }
        let column = columns[2]
        let typeFont = UIFont.systemFont(ofSize: 12.5, weight: .medium)
        let typeLabelWidth = min(textWidth(row.typeText, font: typeFont), column.width - 24)
        let groupWidth = min(24 + typeLabelWidth, column.width)
        let groupX = centeredX(width: groupWidth, in: column)
        let iconRect = CGRect(x: groupX, y: y + 16, width: 17, height: 17)
        fillOval(iconRect, color: chip)
        drawTransferIcon(row.transferType, in: iconRect.insetBy(dx: 3, dy: 3), color: color)
        drawText(
            row.typeText,
            in: CGRect(x: groupX + 24, y: y + 17, width: groupWidth - 24, height: 15),
            font: typeFont,
            color: inkSoft
        )
    }

    private static func drawAmount(_ row: ActivityPDFRow, at y: CGFloat) {
        let column = columns[3]
        let color: UIColor
        switch row.transferType {
        case .received: color = pos
        case .sent: color = ink
        case .internalTransfer: color = faint
        }
        let full = "\(row.amountText) \(row.unitText)"
        let attributed = NSMutableAttributedString(
            string: full,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: color,
                .kern: -0.125
            ]
        )
        let unitRange = (full as NSString).range(of: row.unitText, options: .backwards)
        if unitRange.location != NSNotFound {
            attributed.addAttributes([
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: faint
            ], range: unitRange)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
        attributed.draw(in: CGRect(x: column.x, y: y + 17, width: column.width, height: 15))
    }

    private static func drawStatus(_ row: ActivityPDFRow, at y: CGFloat, height: CGFloat) {
        let color = statusColor(for: row.status)
        let fillColor = color.withAlphaComponent(0.12)
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let width = min(max(textWidth(row.statusText, font: font) + 33, 70), columns[5].width)
        let rect = CGRect(x: centeredX(width: width, in: columns[5]), y: y + 13.5, width: width, height: 22)
        fillRounded(rect, radius: 11, color: fillColor)
        fillOval(CGRect(x: rect.minX + 9, y: rect.midY - 2.5, width: 5, height: 5), color: color)
        drawText(
            row.statusText,
            in: CGRect(x: rect.minX + 19, y: rect.minY + 4, width: rect.width - 25, height: 13),
            font: font,
            color: color
        )
    }

    private static func centeredX(width: CGFloat, in column: Column) -> CGFloat {
        column.x + max(0, (column.width - width) / 2)
    }

    private static func statusColor(for status: ActivityPDFRow.Status) -> UIColor {
        switch status {
        case .confirmed: return pos
        case .pending: return warn
        case .failed: return fail
        }
    }

    private static func amountColor(for row: ActivityPDFRow) -> UIColor {
        switch row.transferType {
        case .received: return pos
        case .sent: return ink
        case .internalTransfer: return inkSoft
        }
    }

    // MARK: - Legal / footer

    private static func drawLegal(document: ActivityPDFDocument) {
        let height: CGFloat = 78
        let y = footerRuleY - 14 - height
        let rect = CGRect(x: sidePadding, y: y, width: contentWidth, height: height)
        fillRounded(rect, radius: 12, color: legalFill)
        strokeRounded(rect, radius: 12, color: hair, lineWidth: 1)
        drawText(
            document.legalTitle.uppercased(),
            in: CGRect(x: rect.minX + 18, y: rect.minY + 15, width: rect.width - 36, height: 13),
            font: .systemFont(ofSize: 11, weight: .bold),
            color: sub,
            kern: 0.66
        )
        drawText(
            document.legalText,
            in: CGRect(x: rect.minX + 18, y: rect.minY + 34, width: rect.width - 36, height: 36),
            font: .systemFont(ofSize: 10.8, weight: .regular),
            color: sub,
            lineHeight: 17
        )
    }

    private static func drawFooter(document: ActivityPDFDocument, page: Int, total: Int, logo: UIImage?) {
        fill(CGRect(x: sidePadding, y: footerRuleY, width: contentWidth, height: 1), color: hair)
        let y = footerRuleY + 14
        if let logo {
            drawRoundedImage(logo, in: CGRect(x: sidePadding, y: y - 1, width: 14, height: 14), radius: 4)
        } else {
            drawLogoFallback(in: CGRect(x: sidePadding, y: y - 1, width: 14, height: 14), radius: 4)
        }
        drawText(
            document.footerSiteText,
            in: CGRect(x: sidePadding + 22, y: y, width: 150, height: 13),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: sub
        )
        drawText(
            "\(document.walletName) · \(document.title)",
            in: CGRect(x: sidePadding + 190, y: y, width: 298, height: 13),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: sub,
            alignment: .center
        )
        let pageText = String(format: document.pageLabelFormat, Int64(page), Int64(total))
        drawText(
            pageText,
            in: CGRect(x: contentRight - 150, y: y, width: 150, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            color: faint,
            alignment: .right
        )
    }

    // MARK: - Drawing helpers

    private static func drawTransferIcon(_ type: ActivityPDFRow.TransferType, in rect: CGRect, color: UIColor) {
        color.setStroke()
        let path = UIBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch type {
        case .received:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY + 1))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY + 1))
        case .sent:
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY - 1))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY - 1))
        case .internalTransfer:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + 3))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 3))
            path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
            path.addLine(to: CGPoint(x: rect.minX + 1, y: rect.maxY - 3))
            path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY))
        }
        path.stroke()
    }

    private static func drawCircleImage(_ image: UIImage, in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            image.draw(in: rect)
            return
        }
        context.saveGState()
        UIBezierPath(ovalIn: rect).addClip()
        image.draw(in: rect)
        context.restoreGState()
        strokeOval(rect, color: hair, lineWidth: 0.6)
    }

    private static func drawRoundedImage(_ image: UIImage, in rect: CGRect, radius: CGFloat) {
        guard let context = UIGraphicsGetCurrentContext() else {
            image.draw(in: rect)
            return
        }
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
        image.draw(in: rect)
        context.restoreGState()
    }

    private static func drawMonogram(_ symbol: String, in rect: CGRect) {
        fillOval(rect, color: chip)
        strokeOval(rect, color: hair, lineWidth: 0.8)
        let text = String(symbol.prefix(3)).uppercased()
        drawText(
            text.isEmpty ? "-" : text,
            in: rect.insetBy(dx: 3, dy: 9),
            font: .systemFont(ofSize: 9.5, weight: .bold),
            color: inkSoft,
            alignment: .center,
            kern: -0.19
        )
    }

    private static func drawLogoFallback(in rect: CGRect, radius: CGFloat) {
        fillRounded(rect, radius: radius, color: ink)
        drawText(
            "A",
            in: rect.insetBy(dx: 0, dy: rect.height * 0.18),
            font: .systemFont(ofSize: rect.height * 0.46, weight: .bold),
            color: .white,
            alignment: .center
        )
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        kern: CGFloat = 0,
        lineHeight: CGFloat? = nil
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineHeight == nil ? .byTruncatingTail : .byWordWrapping
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .kern: kern
            ]
        )
        attributed.draw(in: rect)
    }

    private static func textWidth(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func fill(_ rect: CGRect, color: UIColor) {
        color.setFill()
        UIBezierPath(rect: rect).fill()
    }

    private static func fillRounded(_ rect: CGRect, radius: CGFloat, color: UIColor) {
        color.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
    }

    private static func fillOval(_ rect: CGRect, color: UIColor) {
        color.setFill()
        UIBezierPath(ovalIn: rect).fill()
    }

    private static func strokeRounded(_ rect: CGRect, radius: CGFloat, color: UIColor, lineWidth: CGFloat) {
        color.setStroke()
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static func strokeOval(_ rect: CGRect, color: UIColor, lineWidth: CGFloat) {
        color.setStroke()
        let path = UIBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
