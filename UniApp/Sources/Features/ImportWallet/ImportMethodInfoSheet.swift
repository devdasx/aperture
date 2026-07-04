import SwiftUI

/// Deep, per-method explainer shown when the user taps **Info** on an
/// Import Wallet row (2026-06-20 user direction — the terse trailing
/// captions like "12 or 24 words" were replaced by an Info affordance that
/// opens this sheet). One sheet, four variants; content is honest and
/// on-voice (Rule #16), no marketing.
enum ImportInfo: String, Identifiable, Sendable {
    case iCloud
    case recoveryPhrase
    case privateKey
    case watchOnly

    var id: String { rawValue }

    var heroIcon: String {
        switch self {
        case .iCloud:         return "icloud.and.arrow.down"
        case .recoveryPhrase: return "text.book.closed"
        case .privateKey:     return "key.horizontal"
        case .watchOnly:      return "eye"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .iCloud:         return "Restore from iCloud"
        case .recoveryPhrase: return "Recovery phrase"
        case .privateKey:     return "Private key"
        case .watchOnly:      return "Watch-only"
        }
    }

    var lede: LocalizedStringKey {
        switch self {
        case .iCloud:         return "Bring back a wallet you previously backed up to iCloud."
        case .recoveryPhrase: return "A 12- or 24-word phrase is the master key to an entire wallet."
        case .privateKey:     return "A private key controls a single account on a single network."
        case .watchOnly:      return "Track an address without holding its private key."
        }
    }

    struct Point {
        let icon: String
        let lead: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    var points: [Point] {
        switch self {
        case .iCloud:
            return [
                .init(icon: "lock.shield",
                      lead: "End-to-end encrypted",
                      detail: "Your recovery phrase was encrypted on your device with a password you chose. Only that encrypted copy lives in your private iCloud — Apple and Aperture can never read it."),
                .init(icon: "key",
                      lead: "You'll need your backup password",
                      detail: "It decrypts the phrase on this device. It can't be reset — if you've lost it, the backup can't be opened."),
                .init(icon: "rectangle.stack",
                      lead: "Restores the whole wallet",
                      detail: "Every account on every supported network is rebuilt from the phrase, exactly as it was.")
            ]
        case .recoveryPhrase:
            return [
                .init(icon: "rectangle.stack",
                      lead: "Imports everything",
                      detail: "Every account on every network is derived from these words, so the whole wallet comes in at once."),
                .init(icon: "hand.raised",
                      lead: "Anyone with the words has the funds",
                      detail: "Type them only on a device you trust. Aperture stores them encrypted in this iPhone's local database and never sends them anywhere."),
                .init(icon: "list.number",
                      lead: "12 or 24 words, in order",
                      detail: "Enter them in the exact order they were given — the order is part of the key.")
            ]
        case .privateKey:
            return [
                .init(icon: "link",
                      lead: "One account, one chain",
                      detail: "It brings in just that account. For EVM chains the same key works across every EVM network; your other chains stay outside Aperture until you import their keys or your recovery phrase."),
                .init(icon: "textformat",
                      lead: "In the chain's native format",
                      detail: "Paste it as that chain expects — 0x-hex for Ethereum and EVM, WIF for Bitcoin, base58 for Solana, and so on."),
                .init(icon: "lock.shield",
                      lead: "Stored only on this device",
                      detail: "Encrypted in this iPhone's local database; it never leaves the device.")
            ]
        case .watchOnly:
            return [
                .init(icon: "eye",
                      lead: "See, don't sign",
                      detail: "You can view balances and transaction history, but you can't send or sign anything — there's no private key."),
                .init(icon: "antenna.radiowaves.left.and.right",
                      lead: "An address or an extended key",
                      detail: "Add a single address, or an extended public key (xpub / zpub) to watch a whole Bitcoin account at once."),
                .init(icon: "arrow.up.circle",
                      lead: "Upgrade it later",
                      detail: "Add the private key or recovery phrase any time to turn it into a full, spendable wallet.")
            ]
        }
    }
}

struct ImportMethodInfoSheet: View {
    let info: ImportInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        UniSheet(title: info.title) {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                HStack {
                    Spacer()
                    Image(systemName: info.heroIcon)
                        .font(.system(size: 38, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(UniColors.Icon.secondary)
                        .accessibilityHidden(true)
                    Spacer()
                }

                Text(info.lede)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    ForEach(Array(info.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: UniSpacing.m) {
                            Image(systemName: point.icon)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(UniColors.Icon.secondary)
                                .frame(width: 28, alignment: .center)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.lead)
                                    .font(UniTypography.bodyEmphasized)
                                    .foregroundStyle(UniColors.Text.primary)
                                Text(point.detail)
                                    .font(UniTypography.footnote)
                                    .foregroundStyle(UniColors.Text.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) { dismiss() }
        }
    }
}
