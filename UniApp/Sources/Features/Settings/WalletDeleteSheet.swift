import SwiftUI

/// The single-wallet removal surface — the wallet-scoped sibling of
/// `ResetApertureSheet`. Reset erases *everything* on this iPhone; this
/// erases exactly *one* wallet and leaves every other wallet untouched.
///
/// **No typing, ever (user direction 2026-06-13).** The prior design
/// asked the user to transcribe the wallet's name into a text field.
/// That gate is gone — wallet removal now matches the reset flow: the
/// deliberate physical act that authorizes the removal is the user's
/// *passcode* (a thing they already know and have already used to prove
/// ownership of this device). When no passcode is set, a native
/// `confirmationDialog` (Rule #3) carries the destructive role instead.
/// Either way: zero text inputs.
///
/// **Honesty per wallet kind (Rule #16 §A.6 + Rule #2 §A.7).** The
/// consequence line is the load-bearing sentence and it tells the truth
/// for *this* wallet:
/// - Created / phrase-imported with the phrase stored on this iPhone →
///   removal is reversible: "you can import it again with its recovery
///   phrase." Calm.
/// - Key-imported with the key stored on this iPhone → same calm,
///   reversible shape, named for the private key.
/// - Imported *without* the secret kept on this iPhone → removal here is
///   final unless the user holds the phrase / key somewhere else. Said
///   plainly, in red, once.
/// - Watch-only → nothing secret exists on this device, so nothing
///   secret is lost. The calmest case; no red.
///
/// **Layers (Rule #2 §B.3).** Content layer: this opaque sheet on
/// `Background.primary`. Functional layer: the bottom
/// `GlassEffectContainer` commit and (when armed) the passcode
/// `fullScreenCover`. Two layers, never three.
struct WalletDeleteSheet: View {
    /// The wallet's display name — names the title, the intro line, and
    /// the inventory header so the user always sees *which* wallet is
    /// about to go.
    let walletName: String
    /// The wallet's kind, which selects the consequence sentence.
    let kind: WalletKind
    /// Count of distinct networks this wallet holds addresses on. Drives
    /// the "addresses on N networks" inventory row. Pre-resolved by the
    /// caller (`Set(addresses.map(\.chainRaw)).count`) so this view does
    /// no model traversal of its own.
    let networkCount: Int
    /// `true` iff this wallet's encrypted secret (seed / phrase / key)
    /// is actually held in the Keychain on this iPhone — resolved by the
    /// caller from `MnemonicVault`. Selects between the reversible and
    /// the final consequence line for imported wallets, and decides
    /// whether the "encrypted secret" inventory row appears at all.
    let hasStoredSecret: Bool

    /// Fires once the user has *authorized* the removal — passcode
    /// verified, or the no-passcode confirmation accepted. The parent
    /// runs the real `deleteWalletAndActivateNext(walletId:)` here; this
    /// view never touches wallet data.
    let onAuthorized: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Armed when the destructive CTA is tapped and a passcode exists.
    /// Drives the passcode-only verify gate.
    @State private var isShowingPasscodeGate: Bool = false
    /// Armed when the destructive CTA is tapped and *no* passcode exists.
    /// Drives the native destructive `confirmationDialog`.
    @State private var isShowingNoPasscodeConfirm: Bool = false

    var body: some View {
        NavigationStack {
            // Short, fixed content — no `ScrollView` per Rule #15. The
            // bottom commit lives in a `safeAreaInset` so it floats over
            // the content as Liquid Glass chrome.
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero

                UniBody(
                    text: "This removes \(walletName) from this iPhone. Every other wallet stays exactly as it is.",
                    color: UniColors.Text.secondary
                )

                erasedList

                consequenceLine

                Spacer(minLength: UniSpacing.xs)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Remove wallet"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                GlassEffectContainer(spacing: UniSpacing.s) {
                    UniButton(
                        title: "Remove this wallet",
                        variant: .destructive
                    ) {
                        beginAuthorization()
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }
        }
        // No passcode set → native destructive confirmation. Still zero
        // typing: the user makes one deliberate, system-rendered choice.
        .confirmationDialog(
            Text("Remove \(walletName)?"),
            isPresented: $isShowingNoPasscodeConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove wallet", role: .destructive) {
                onAuthorized()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(noPasscodeConfirmMessage)
        }
        // Passcode set → the passcode itself is the deliberate act that
        // authorizes the removal. Passcode-only per user direction
        // 2026-06-13: `allowsBiometrics: false` means no Face ID
        // auto-prompt and no biometric keypad key, even when Face ID is
        // enabled. Same presentation shape as `ResetApertureSheet` and
        // the Security entry gate (Rule #15 + Rule #17).
        .fullScreenCover(isPresented: $isShowingPasscodeGate) {
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isShowingPasscodeGate = false
                        onAuthorized()
                    },
                    onCancel: {
                        // Declining to authenticate aborts the removal
                        // entirely — nothing is touched.
                        isShowingPasscodeGate = false
                    },
                    allowsBiometrics: false
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingPasscodeGate = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Cancel"))
                    }
                }
            }
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    /// Route the commit to the passcode gate when one is set, otherwise
    /// to the native destructive confirmation. Both paths require zero
    /// typing.
    private func beginAuthorization() {
        if PinCodeStorage.hasPin {
            isShowingPasscodeGate = true
        } else {
            isShowingNoPasscodeConfirm = true
        }
    }

    // MARK: - Hero

    private var hero: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: 52, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Status.errorForeground)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, UniSpacing.xxs)
            .accessibilityHidden(true)
    }

    // MARK: - What gets removed (this wallet's scope)

    /// A tight, scannable inventory of what removal takes from *this*
    /// wallet — real structure (a `UniCard` of rows) instead of prose,
    /// so the scope reads at a glance. Each row is one category, leading
    /// SF Symbol + label, no decoration. The encrypted-secret row only
    /// appears when a secret actually lives on this iPhone — a
    /// watch-only wallet (or an import whose secret was never kept) holds
    /// none, so naming one would be a lie (Rule #16 §A).
    private var erasedList: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                erasedRow(symbol: "number", label: addressesRowLabel)
                UniDivider()
                erasedRow(symbol: "chart.line.uptrend.xyaxis", label: "Its transaction and chart history on this iPhone")
                if hasStoredSecret {
                    UniDivider()
                    erasedRow(symbol: "key.fill", label: secretRowLabel)
                }
            }
        }
    }

    private func erasedRow(symbol: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 26, alignment: .center)
                .accessibilityHidden(true)
            UniBody(text: label, color: UniColors.Text.primary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Consequence line (per kind)

    /// The single honest consequence sentence. Reversible cases (a secret
    /// is stored, or there's no secret to lose) stay calm in
    /// `Text.secondary`; the one genuinely-final case (an import whose
    /// secret was never kept) is stated plainly in red, once — never as
    /// decoration (Rule #16 §B).
    @ViewBuilder
    private var consequenceLine: some View {
        switch kind {
        case .watchOnly:
            UniBody(
                text: "This wallet only watches an address — nothing secret is stored on this iPhone, so nothing secret is lost. You can add it again anytime.",
                color: UniColors.Text.secondary
            )
        case .created, .importedMnemonic:
            if hasStoredSecret {
                UniBody(
                    text: "Your recovery phrase stays yours. You can import this wallet again with it — there is no server, and removing it here loses nothing you've written down.",
                    color: UniColors.Text.secondary
                )
            } else {
                UniBody(
                    text: "This wallet's recovery phrase isn't stored on this iPhone. Unless you have it written down elsewhere, removing it here is final — the funds in it can't be recovered.",
                    color: UniColors.Status.errorForeground
                )
            }
        case .importedKey:
            if hasStoredSecret {
                UniBody(
                    text: "Your private key stays yours. You can import this wallet again with it — there is no server, and removing it here loses nothing you've saved.",
                    color: UniColors.Text.secondary
                )
            } else {
                UniBody(
                    text: "This wallet's private key isn't stored on this iPhone. Unless you have it saved elsewhere, removing it here is final — the funds in it can't be recovered.",
                    color: UniColors.Status.errorForeground
                )
            }
        }
    }

    // MARK: - Copy resolution

    /// "Its address" (singular) for a one-network wallet, "Its addresses
    /// on N networks" otherwise — honest about scope without inventing a
    /// plural that isn't there.
    private var addressesRowLabel: LocalizedStringKey {
        if networkCount <= 1 {
            return "Its address on this iPhone"
        }
        return "Its addresses on \(networkCount) networks"
    }

    /// Names the secret by what it actually is, so the row matches the
    /// reveal vocabulary elsewhere in the app (phrase vs. key).
    private var secretRowLabel: LocalizedStringKey {
        switch kind {
        case .importedKey:
            return "Its encrypted private key in the Keychain"
        default:
            return "Its encrypted recovery phrase in the Keychain"
        }
    }

    /// Body line for the no-passcode native confirmation. Mirrors the
    /// consequence line's per-kind honesty in the compact form the
    /// system dialog allows.
    private var noPasscodeConfirmMessage: LocalizedStringKey {
        switch kind {
        case .watchOnly:
            return "This only stops watching the address. Nothing secret is stored, so nothing is lost."
        case .created, .importedMnemonic, .importedKey:
            if hasStoredSecret {
                return "You can import this wallet again with its recovery phrase or key. Other wallets are untouched."
            }
            return "This wallet's secret isn't stored here. Unless you have it elsewhere, this can't be undone."
        }
    }
}
