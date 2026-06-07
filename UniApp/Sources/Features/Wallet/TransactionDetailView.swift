import SwiftUI
import SwiftData

/// Push destination shown when the user taps a transaction row on
/// the wallet home. v1 is a calm read-only summary — the full design
/// (block explorer link, contract data decoding, receipt rendering)
/// lands later.
struct TransactionDetailView: View {
    let transactionId: UUID
    @Query private var matches: [TransactionRecord]

    init(transactionId: UUID) {
        self.transactionId = transactionId
        _matches = Query(
            filter: #Predicate<TransactionRecord> { $0.id == transactionId },
            sort: \TransactionRecord.occurredAt
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                if let tx = matches.first {
                    header(tx)
                    detailGrid(tx)
                } else {
                    missing
                }
            }
            .padding(UniSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ tx: TransactionRecord) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text(directionLabel(tx))
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            Text(amountLine(tx))
                .font(UniTypography.heroBalance)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            statusBadge(tx)
        }
    }

    private func statusBadge(_ tx: TransactionRecord) -> some View {
        let status = TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed
        let kind: UniBadge.Kind
        let label: LocalizedStringKey
        switch status {
        case .pending:   kind = .warning; label = "Pending"
        case .confirmed: kind = .success; label = "Confirmed"
        case .failed:    kind = .error;   label = "Failed"
        }
        return UniBadge(text: label, kind: kind)
    }

    private func detailGrid(_ tx: TransactionRecord) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            detailRow(label: "Counterparty", value: tx.counterparty.isEmpty ? "—" : WalletFormatting.shortAddress(tx.counterparty))
            UniDivider()
            detailRow(label: "When", value: tx.occurredAt.formatted(date: .abbreviated, time: .shortened))
            UniDivider()
            detailRow(label: "Hash", value: WalletFormatting.shortAddress(tx.txHash, prefix: 10, suffix: 6))
            if let block = tx.blockNumber {
                UniDivider()
                detailRow(label: "Block", value: String(block))
            }
            if let fee = tx.feeRaw {
                UniDivider()
                detailRow(label: "Fee", value: fee)
            }
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Material.card)
        )
    }

    private func detailRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(value)
                .font(UniTypography.monoBody)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }

    private var missing: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
            UniBody(
                text: "This transaction is no longer in the local store.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
        .frame(maxWidth: .infinity)
        .padding(UniSpacing.xl)
    }

    private func directionLabel(_ tx: TransactionRecord) -> String {
        switch TransactionDirection(rawValue: tx.directionRaw) {
        case .incoming?: return String.apertureLocalized("Received")
        case .outgoing?: return String.apertureLocalized("Sent")
        case .internal?: return String.apertureLocalized("Internal transfer")
        case nil:        return String.apertureLocalized("Transaction")
        }
    }

    private func amountLine(_ tx: TransactionRecord) -> String {
        let amount = Decimal(string: tx.amountRaw) ?? .zero
        let formatted = WalletFormatting.native(amount, decimals: 8)
        let sign: String
        switch TransactionDirection(rawValue: tx.directionRaw) {
        case .incoming?: sign = "+"
        case .outgoing?: sign = "−"
        default:         sign = ""
        }
        return "\(sign)\(formatted) \(tx.tokenSymbol)"
    }
}
