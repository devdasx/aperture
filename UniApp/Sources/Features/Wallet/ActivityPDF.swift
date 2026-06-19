import UIKit

/// **Modern PDF export of the Activity list.** Renders the user's
/// filtered transactions into a branded, multi-page A-list statement —
/// app logo, name, an App Store download QR, the active filter summary,
/// and a clean zebra-striped table. Every string is supplied by the
/// caller already localized, so the document honors the user's language
/// (RTL included via the per-row alignment the caller picks).
///
/// **Why a hand-rolled `UIGraphicsPDFRenderer` (not PDFKit authoring).**
/// PDFKit reads/annotates existing PDFs; it doesn't lay out original
/// content. The system path for *creating* a vector PDF from scratch is
/// `UIGraphicsPDFRenderer.pdfData { ctx in ctx.beginPage(); … }`, drawing
/// each page with Core Graphics + `NSAttributedString`. That is exactly
/// what this type does — verified against Apple's UIGraphicsPDFRenderer
/// reference (init(bounds:format:), pdfData(_:), beginPage(),
/// `context.cgContext`).
///
/// **Pagination.** Page 1 carries the full header (logo + QR + meta +
/// filter summary); continuation pages start straight into the table.
/// Every page repeats the column header and a footer (page X of Y).
/// `totalPages(for:)` precomputes Y so the footer is honest before the
/// first page is drawn.

// MARK: - Value model (one snapshot row)

/// One table row, fully pre-formatted by the caller (dates localized,
/// amounts/fiat rendered, status mapped). The renderer draws strings —
/// it does no formatting, pricing, or locale work itself.
struct ActivityPDFRow {
    let dateText: String
    let assetSymbol: String
    let networkName: String
    let typeText: String
    /// Drives the amount tint — incoming reads positive (green).
    let isIncoming: Bool
    let amountText: String
    let fiatText: String
    let statusText: String
    let status: Status

    enum Status { case confirmed, pending, failed }
}

/// Everything the document needs besides the rows. Built (localized) by
/// the view; the renderer never reaches for a bundle string itself.
struct ActivityPDFDocument {
    let appName: String
    let title: String
    let walletName: String
    let generatedText: String
    let summaryText: String
    /// Active-filter descriptions, one per line. Empty = no filter band.
    let filterLines: [String]
    let downloadCaption: String
    let appStoreURLText: String
    let footerText: String
    /// `String(format:)` template for "Page %1$lld of %2$lld" (localized).
    let pageLabelFormat: String
    let emptyText: String

    // Column headers (localized).
    let colDate: String
    let colAsset: String
    let colType: String
    let colAmount: String
    let colValue: String
    let colStatus: String

    /// `true` when the document language is right-to-left, so the
    /// renderer mirrors column alignment.
    let isRTL: Bool
}

// MARK: - Renderer

enum ActivityPDFRenderer {

    // US Letter, portrait. The most universally printable page size.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 44
    private static let rowHeight: CGFloat = 22
    private static let footerHeight: CGFloat = 26
    private static let columnHeaderHeight: CGFloat = 20

    private static var contentWidth: CGFloat { pageSize.width - margin * 2 }
    private static var pageBottom: CGFloat { pageSize.height - margin - footerHeight }

    // Document palette — neutral ink on white (prints cleanly), with a
    // single brand accent pulled from the asset catalog when available.
    private static let ink = UIColor(white: 0.11, alpha: 1)
    private static let secondary = UIColor(white: 0.40, alpha: 1)
    private static let tertiary = UIColor(white: 0.56, alpha: 1)
    private static let hairline = UIColor(white: 0.86, alpha: 1)
    private static let zebra = UIColor(white: 0.968, alpha: 1)
    private static let headerFill = UIColor(white: 0.945, alpha: 1)
    private static let positive = UIColor(red: 0.13, green: 0.52, blue: 0.32, alpha: 1)
    private static var accent: UIColor { UIColor(named: "BrandMark") ?? UIColor(red: 0.36, green: 0.34, blue: 0.86, alpha: 1) }
    private static let pending = UIColor(red: 0.78, green: 0.55, blue: 0.0, alpha: 1)
    private static let failed = UIColor(red: 0.78, green: 0.20, blue: 0.20, alpha: 1)

    /// Column x-origins + widths, left to right (LTR). Sum == contentWidth.
    private struct Columns {
        static let date: CGFloat = 96
        static let asset: CGFloat = 116
        static let type: CGFloat = 64
        static let amount: CGFloat = 104
        static let value: CGFloat = 82
        static let status: CGFloat = 62  // 96+116+64+104+82+62 = 524 = contentWidth
    }

    /// Render the full document to PDF `Data`.
    ///
    /// - Parameters:
    ///   - rows: the filtered, sorted rows (already snapshotted).
    ///   - document: localized labels + metadata.
    ///   - logo: the app mark (LogoCircle); skipped if nil.
    ///   - qr: the App Store download QR; skipped if nil.
    static func render(
        rows: [ActivityPDFRow],
        document: ActivityPDFDocument,
        logo: UIImage?,
        qr: UIImage?
    ) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(document.appName) — \(document.title)",
            kCGPDFContextCreator as String: document.appName
        ]
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        let pages = max(1, totalPages(for: rows.count, hasFilterLines: !document.filterLines.isEmpty))

        return renderer.pdfData { ctx in
            var pageIndex = 0
            var rowCursor = 0

            // Page 1 — full header.
            pageIndex += 1
            ctx.beginPage()
            var y = drawHeader(document: document, logo: logo, qr: qr)
            y = drawColumnHeader(document: document, at: y)
            rowCursor = drawRows(rows, from: rowCursor, startY: y, document: document)
            drawFooter(document: document, page: pageIndex, of: pages)

            // Continuation pages — table only.
            while rowCursor < rows.count {
                pageIndex += 1
                ctx.beginPage()
                var cy = margin
                cy = drawColumnHeader(document: document, at: cy)
                rowCursor = drawRows(rows, from: rowCursor, startY: cy, document: document)
                drawFooter(document: document, page: pageIndex, of: pages)
            }

            // Zero-row safety: a valid one-page document still says so.
            if rows.isEmpty {
                drawEmptyState(document: document, at: y)
            }
        }
    }

    // MARK: - Pagination math

    /// Pages required for `rowCount`, given page 1 loses height to the
    /// header (and optional filter band) while continuation pages don't.
    static func totalPages(for rowCount: Int, hasFilterLines: Bool) -> Int {
        guard rowCount > 0 else { return 1 }
        let headerHeight = estimatedHeaderHeight(hasFilterLines: hasFilterLines)
        let page1Top = margin + headerHeight + columnHeaderHeight
        let contTop = margin + columnHeaderHeight
        let rowsPage1 = max(1, Int((pageBottom - page1Top) / rowHeight))
        let rowsCont = max(1, Int((pageBottom - contTop) / rowHeight))
        if rowCount <= rowsPage1 { return 1 }
        return 1 + Int(ceil(Double(rowCount - rowsPage1) / Double(rowsCont)))
    }

    private static func estimatedHeaderHeight(hasFilterLines: Bool) -> CGFloat {
        // MUST equal exactly what `drawHeader` advances `y` by (its
        // returned value minus `margin`), or the precomputed "of Y" page
        // count drifts from the page breaks the draw loop actually takes.
        // Breakdown, matching drawHeader step-for-step:
        //   logo/QR row + gap ............ max(36,56) + 10 = 66
        //   accent rule + gap ............ 10
        //   wallet name line ............. 16
        //   generated / summary line ..... 18
        //   tail (filter band 30 + gap 8) = 38, else 4
        var height: CGFloat = 66 + 10 + 16 + 18 // = 110
        height += hasFilterLines ? 38 : 4
        return height
    }

    // MARK: - Header

    /// Draws the page-1 header and returns the y where the table can begin.
    private static func drawHeader(
        document: ActivityPDFDocument,
        logo: UIImage?,
        qr: UIImage?
    ) -> CGFloat {
        let left = margin
        let right = pageSize.width - margin
        var y = margin

        // Logo (left).
        let logoSize: CGFloat = 36
        if let logo {
            logo.draw(in: CGRect(x: left, y: y, width: logoSize, height: logoSize))
        }

        // App name + title (left, beside the logo).
        let textX = logo == nil ? left : left + logoSize + 10
        draw(document.appName, at: CGPoint(x: textX, y: y + 1),
             font: .systemFont(ofSize: 16, weight: .semibold), color: ink)
        draw(document.title, at: CGPoint(x: textX, y: y + 20),
             font: .systemFont(ofSize: 11, weight: .regular), color: secondary)

        // QR (right) + caption beneath.
        let qrSize: CGFloat = 56
        if let qr {
            let qrX = right - qrSize
            qr.draw(in: CGRect(x: qrX, y: y, width: qrSize, height: qrSize))
            drawCentered(document.downloadCaption,
                         in: CGRect(x: right - 130, y: y + qrSize + 2, width: 130, height: 12),
                         font: .systemFont(ofSize: 7, weight: .medium), color: tertiary)
            drawCentered(document.appStoreURLText,
                         in: CGRect(x: right - 130, y: y + qrSize + 13, width: 130, height: 12),
                         font: .systemFont(ofSize: 6.5, weight: .regular), color: tertiary)
        }

        y += max(logoSize, qrSize) + 10

        // Accent rule under the header.
        fill(CGRect(x: left, y: y, width: contentWidth, height: 1.5), color: accent)
        y += 10

        // Meta block — wallet, generated, summary.
        draw(document.walletName, at: CGPoint(x: left, y: y),
             font: .systemFont(ofSize: 12, weight: .semibold), color: ink)
        y += 16
        draw(document.generatedText, at: CGPoint(x: left, y: y),
             font: .systemFont(ofSize: 9.5, weight: .regular), color: secondary)
        draw(document.summaryText, at: CGPoint(x: left, y: y),
             font: .systemFont(ofSize: 9.5, weight: .semibold), color: ink,
             rightAlignedIn: CGRect(x: left, y: y, width: contentWidth, height: 12))
        y += 18

        // Filter summary band.
        if !document.filterLines.isEmpty {
            let bandText = document.filterLines.joined(separator: "   •   ")
            let bandRect = CGRect(x: left, y: y, width: contentWidth, height: 30)
            fillRounded(bandRect, radius: 6, color: headerFill)
            draw(bandText,
                 in: bandRect.insetBy(dx: 10, dy: 8),
                 font: .systemFont(ofSize: 8.5, weight: .regular), color: secondary)
            y += 30 + 8
        } else {
            y += 4
        }

        return y
    }

    // MARK: - Column header

    private static func drawColumnHeader(document: ActivityPDFDocument, at top: CGFloat) -> CGFloat {
        let rect = CGRect(x: margin, y: top, width: contentWidth, height: columnHeaderHeight)
        fill(rect, color: headerFill)
        let labels = orderedColumns(document)
        let font = UIFont.systemFont(ofSize: 8, weight: .semibold)
        for col in labels {
            let cell = col.frame(top: top, height: columnHeaderHeight).insetBy(dx: 5, dy: 0)
            drawVerticallyCentered(col.title.uppercased(), in: cell, font: font, color: tertiary,
                                   alignment: col.alignment(isRTL: document.isRTL))
        }
        return top + columnHeaderHeight
    }

    // MARK: - Rows

    /// Draws rows starting at `from`, stopping when the page is full.
    /// Returns the next un-drawn row index.
    private static func drawRows(
        _ rows: [ActivityPDFRow],
        from start: Int,
        startY: CGFloat,
        document: ActivityPDFDocument
    ) -> Int {
        var y = startY
        var index = start
        let cellFont = UIFont.systemFont(ofSize: 9.5, weight: .regular)
        let amountFont = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let subFont = UIFont.systemFont(ofSize: 7.5, weight: .regular)

        while index < rows.count {
            if y + rowHeight > pageBottom { break }
            let row = rows[index]
            let rowRect = CGRect(x: margin, y: y, width: contentWidth, height: rowHeight)
            if index % 2 == 1 { fill(rowRect, color: zebra) }

            let cols = orderedColumns(document)
            // Date
            drawVerticallyCentered(row.dateText, in: cols[0].frame(top: y, height: rowHeight).insetBy(dx: 5, dy: 0),
                                   font: cellFont, color: ink, alignment: cols[0].alignment(isRTL: document.isRTL))
            // Asset (symbol + network sub-line)
            let assetRect = cols[1].frame(top: y, height: rowHeight).insetBy(dx: 5, dy: 0)
            draw(row.assetSymbol, at: CGPoint(x: assetRect.minX, y: y + 4),
                 font: .systemFont(ofSize: 9.5, weight: .semibold), color: ink)
            draw(row.networkName, at: CGPoint(x: assetRect.minX, y: y + 13),
                 font: subFont, color: tertiary)
            // Type
            drawVerticallyCentered(row.typeText, in: cols[2].frame(top: y, height: rowHeight).insetBy(dx: 5, dy: 0),
                                   font: cellFont, color: secondary, alignment: cols[2].alignment(isRTL: document.isRTL))
            // Amount (tinted by direction)
            drawVerticallyCentered(row.amountText, in: cols[3].frame(top: y, height: rowHeight).insetBy(dx: 5, dy: 0),
                                   font: amountFont, color: row.isIncoming ? positive : ink,
                                   alignment: cols[3].alignmentTrailing(isRTL: document.isRTL))
            // Value (fiat)
            drawVerticallyCentered(row.fiatText, in: cols[4].frame(top: y, height: rowHeight).insetBy(dx: 5, dy: 0),
                                   font: amountFont, color: secondary,
                                   alignment: cols[4].alignmentTrailing(isRTL: document.isRTL))
            // Status (dot + text)
            drawStatus(row, in: cols[5].frame(top: y, height: rowHeight).insetBy(dx: 5, dy: 0), isRTL: document.isRTL)

            // Row hairline.
            fill(CGRect(x: margin, y: y + rowHeight - 0.5, width: contentWidth, height: 0.5), color: hairline)
            y += rowHeight
            index += 1
        }
        return index
    }

    private static func drawStatus(_ row: ActivityPDFRow, in rect: CGRect, isRTL: Bool) {
        let color: UIColor
        switch row.status {
        case .confirmed: color = positive
        case .pending:   color = pending
        case .failed:    color = failed
        }
        let dot: CGFloat = 5
        let dotY = rect.midY - dot / 2
        let dotX = isRTL ? rect.maxX - dot : rect.minX
        fillOval(CGRect(x: dotX, y: dotY, width: dot, height: dot), color: color)
        let textRect = isRTL
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width - dot - 4, height: rect.height)
            : CGRect(x: rect.minX + dot + 4, y: rect.minY, width: rect.width - dot - 4, height: rect.height)
        drawVerticallyCentered(row.statusText, in: textRect,
                               font: .systemFont(ofSize: 8, weight: .regular), color: secondary,
                               alignment: isRTL ? .right : .left)
    }

    // MARK: - Footer

    private static func drawFooter(document: ActivityPDFDocument, page: Int, of total: Int) {
        let y = pageSize.height - margin - footerHeight + 8
        fill(CGRect(x: margin, y: y, width: contentWidth, height: 0.75), color: hairline)
        let textY = y + 6
        draw(document.footerText, at: CGPoint(x: margin, y: textY),
             font: .systemFont(ofSize: 8, weight: .regular), color: tertiary)
        let pageText = String(format: document.pageLabelFormat, page, total)
        draw(pageText, at: CGPoint(x: margin, y: textY),
             font: .systemFont(ofSize: 8, weight: .regular), color: tertiary,
             rightAlignedIn: CGRect(x: margin, y: textY, width: contentWidth, height: 10))
    }

    private static func drawEmptyState(document: ActivityPDFDocument, at top: CGFloat) {
        drawCentered(document.emptyText,
                     in: CGRect(x: margin, y: top + 40, width: contentWidth, height: 20),
                     font: .systemFont(ofSize: 11, weight: .regular), color: tertiary)
    }

    // MARK: - Column ordering / geometry

    private struct Column {
        let title: String
        let x: CGFloat
        let width: CGFloat
        let trailing: Bool

        func frame(top: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: x, y: top, width: width, height: height)
        }
        func alignment(isRTL: Bool) -> NSTextAlignment { isRTL ? .right : .left }
        func alignmentTrailing(isRTL: Bool) -> NSTextAlignment { isRTL ? .left : .right }
    }

    /// The six columns with LTR x-origins. For RTL the same frames are
    /// used but text alignment flips (mirroring whole-page geometry for a
    /// table is overkill; flipped alignment reads correctly).
    private static func orderedColumns(_ document: ActivityPDFDocument) -> [Column] {
        var x = margin
        func next(_ title: String, _ w: CGFloat, trailing: Bool = false) -> Column {
            let c = Column(title: title, x: x, width: w, trailing: trailing)
            x += w
            return c
        }
        return [
            next(document.colDate, Columns.date),
            next(document.colAsset, Columns.asset),
            next(document.colType, Columns.type),
            next(document.colAmount, Columns.amount, trailing: true),
            next(document.colValue, Columns.value, trailing: true),
            next(document.colStatus, Columns.status)
        ]
    }

    // MARK: - Low-level draw helpers

    private static func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func draw(
        _ text: String, at point: CGPoint, font: UIFont, color: UIColor,
        rightAlignedIn rect: CGRect
    ) {
        let para = NSMutableParagraphStyle(); para.alignment = .right
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ])
    }

    private static func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ])
    }

    private static func drawCentered(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ])
    }

    private static func drawVerticallyCentered(
        _ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment
    ) {
        let para = NSMutableParagraphStyle(); para.alignment = alignment; para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let textHeight = font.lineHeight
        let centeredRect = CGRect(x: rect.minX, y: rect.midY - textHeight / 2, width: rect.width, height: textHeight)
        (text as NSString).draw(in: centeredRect, withAttributes: attrs)
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
}
