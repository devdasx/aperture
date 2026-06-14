import SwiftUI

// MARK: - F1 · Share receipt
//
/// **Send v2 · F1 — Share receipt (bottom sheet).** A keepable white
/// receipt card — iris disc, amount, recipient + date, hairline, network +
/// tx hash, "APERTURE · RECEIPT" — above the system share row (native
/// `ShareLink`). The image never includes the sender's balance (handoff).
///
/// Rule #15: native `NavigationStack` + `.navigationTitle`. Rule #3: the
/// share row is the native `ShareLink`, not a custom share UI.
struct SendV2ShareReceiptSheet: View {
    @Bindable var model: SendV2Model
    let amountText: String
    let recipientDisplay: String
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    private var draft: SendDraft { model.draft }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    receiptCard
                    shareRow
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The keepable receipt card — a real designed artifact (the screen
    /// renders it; a future turn snapshots it to a shareable image via
    /// `ImageRenderer`).
    private var receiptCard: some View {
        VStack(spacing: UniSpacing.m) {
            ApertureIrisView(ringColor: UniColors.Brand.mark)
                .frame(width: 44, height: 44)

            Text(verbatim: "\(amountText)")
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .tracking(-0.6)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
            Text(verbatim: "to \(recipientDisplay)")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Text(verbatim: dateText)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)

            UniDivider()

            VStack(spacing: UniSpacing.xs) {
                receiptLine(key: "Network", value: draft.network?.displayName ?? "")
                receiptLine(key: "Fee", value: WalletFormatting.fiat(model.networkFeeFiat, currencyCode: activeCurrencyCode))
                receiptLine(key: "Transaction", value: SendDraft.shorten(model.transactionHash, prefix: 8, suffix: 6))
            }

            Text("APERTURE · RECEIPT")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(UniColors.Text.quaternary)
                .padding(.top, UniSpacing.xs)
        }
        .padding(UniSpacing.l)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous)
                .fill(UniColors.Material.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous)
                .stroke(UniColors.Stroke.regular, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Receipt: \(amountText) to \(recipientDisplay)"))
    }

    @ViewBuilder
    private func receiptLine(key: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(key)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(UniTypography.footnote.monospaced())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var shareRow: some View {
        VStack(spacing: UniSpacing.s) {
            ShareLink(item: explorerURL) {
                HStack(spacing: UniSpacing.xs) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                    Text("Share receipt")
                        .font(UniTypography.buttonLabel)
                }
                .foregroundStyle(UniColors.Send.onDarkGlass)
                .frame(maxWidth: .infinity)
                .frame(height: 47)
                .background(Capsule().fill(UniColors.Send.darkGlass))
                .contentShape(Capsule())
            }
            .accessibilityLabel(Text("Share receipt"))

            Button {
                UIPasteboard.general.string = explorerURL.absoluteString
            } label: {
                Text("Copy link")
                    .font(UniTypography.buttonLabel)
                    .foregroundStyle(UniColors.Text.link)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // `.success` when the copy confirmation shows (handoff).
            .uniHaptic(.success, trigger: copyTick)
            .simultaneousGesture(TapGesture().onEnded { copyTick += 1 })
        }
    }

    @State private var copyTick: Int = 0

    private var explorerURL: URL {
        URL(string: "https://etherscan.io/tx/\(model.transactionHash)") ?? URL(string: "https://etherscan.io")!
    }

    private var dateText: String {
        Date.now.formatted(date: .abbreviated, time: .shortened)
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}

// MARK: - F2 · Explorer (in-app browser stub)

/// **Send v2 · F2 — Explorer.** Glass top bar (back, 🔒 etherscan.io pill,
/// share), a transaction table (hash, Success · confirmations, From/To,
/// Value, Fee, Block), and a footnote: *"Opened in Aperture's in-app
/// browser — your wallet stays disconnected."* **Open in Safari** at the
/// bottom (native `Link`).
///
/// DESIGN stub: the table is rendered statically (no `WKWebView` — the real
/// explorer is the in-app browser, a separate feature). Rule #15: native
/// `NavigationStack`.
struct SendV2ExplorerSheet: View {
    @Bindable var model: SendV2Model
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    private var draft: SendDraft { model.draft }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.m) {
                    urlBar
                    SendGlassCard(padding: UniSpacing.m) {
                        VStack(spacing: 0) {
                            row("Status") {
                                HStack(spacing: UniSpacing.xxs) {
                                    Circle().fill(UniColors.Send.positive).frame(width: 7, height: 7)
                                    Text("Success · 14 confirmations")
                                        .font(UniTypography.subheadlineEmphasized)
                                        .foregroundStyle(UniColors.Send.positive)
                                }
                            }
                            UniDivider()
                            row("Hash") { mono(SendDraft.shorten(model.transactionHash, prefix: 8, suffix: 6)) }
                            UniDivider()
                            row("Value") { mono("\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)") }
                            UniDivider()
                            row("Fee") { mono(WalletFormatting.fiat(model.networkFeeFiat, currencyCode: activeCurrencyCode)) }
                            UniDivider()
                            row("Block") { mono("21,482,113") }
                        }
                    }
                    Text("Opened in Aperture's in-app browser — your wallet stays disconnected.")
                        .font(UniTypography.caption2)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, UniSpacing.m)
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                Link(destination: explorerURL) {
                    HStack(spacing: UniSpacing.xs) {
                        Image(systemName: "safari")
                        Text("Open in Safari")
                    }
                    .font(UniTypography.buttonLabel)
                    .foregroundStyle(UniColors.Text.link)
                    .frame(maxWidth: .infinity)
                    .frame(height: 47)
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.s)
                .background(.bar)
            }
            .background(UniColors.Background.primary)
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var urlBar: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(UniColors.Send.positive)
            Text(verbatim: "etherscan.io")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.m)
        .frame(height: 40)
        .background(Capsule().fill(UniColors.Fill.tertiary))
    }

    @ViewBuilder
    private func row<Trailing: View>(_ key: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        SendDetailRow(key: key, trailing: trailing)
    }

    @ViewBuilder
    private func mono(_ value: String) -> some View {
        Text(verbatim: value)
            .font(UniTypography.subheadline.monospaced())
            .foregroundStyle(UniColors.Text.primary)
            .environment(\.layoutDirection, .leftToRight)
    }

    private var explorerURL: URL {
        URL(string: "https://etherscan.io/tx/\(model.transactionHash)") ?? URL(string: "https://etherscan.io")!
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}
