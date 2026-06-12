import SwiftUI

/// The Reset Aperture confirmation surface — the app's single most
/// consequential action.
///
/// **No typing, ever (user direction 2026-06-13).** The prior design
/// asked the user to transcribe "RESET APERTURE" into a text field.
/// That gate is gone. The deliberate physical act that authorizes the
/// wipe is now the user's *passcode* — a thing they already know and
/// have already used to prove ownership of this device. When no
/// passcode is set, a native `confirmationDialog` (Rule #3) carries
/// the destructive role instead. Either way: zero text inputs.
///
/// **Honesty (Rule #16).** The sheet states three things plainly:
/// what gets erased (every wallet, seed, balance, and preference on
/// *this* iPhone), the one irreversible consequence (a wallet whose
/// recovery phrase you never wrote down is gone), and the calm escape
/// hatch (a wallet you *did* back up can always be imported again).
/// Red is reserved for the genuinely destructive accents — the hero
/// and the single consequence line — never as decoration.
///
/// **Layers (Rule #2 §B.3).** Content layer: this opaque sheet on
/// `Background.primary`. Functional layer: the bottom
/// `GlassEffectContainer` commit and (when armed) the passcode
/// `fullScreenCover`. Two layers, never three.
struct ResetApertureSheet: View {
    /// Fires once the user has *authorized* the wipe — passcode verified,
    /// or the no-passcode confirmation accepted. The parent runs the
    /// real `resetAll()` here; this view never touches wallet data.
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
                    text: "This erases everything Aperture keeps on this iPhone. A wallet you backed up can be imported again with its recovery phrase.",
                    color: UniColors.Text.secondary
                )

                erasedList

                UniBody(
                    text: "A wallet whose recovery phrase you never wrote down cannot be recovered. There is no backup on a server — there is no server.",
                    color: UniColors.Status.errorForeground
                )

                Spacer(minLength: UniSpacing.xs)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Reset Aperture"))
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
                        title: "Erase this iPhone's wallets",
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
            Text("Erase this iPhone's wallets?"),
            isPresented: $isShowingNoPasscodeConfirm,
            titleVisibility: .visible
        ) {
            Button("Erase everything", role: .destructive) {
                onAuthorized()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Wallets you didn't back up will be lost.")
        }
        // Passcode set → the passcode itself is the deliberate act that
        // authorizes the wipe. Passcode-only per user direction
        // 2026-06-13: `allowsBiometrics: false` means no Face ID
        // auto-prompt and no biometric keypad key, even when Face ID is
        // enabled. Same presentation shape as the Security entry gate
        // and the wallet-removal gate (Rule #15 + Rule #17).
        .fullScreenCover(isPresented: $isShowingPasscodeGate) {
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isShowingPasscodeGate = false
                        onAuthorized()
                    },
                    onCancel: {
                        // Declining to authenticate aborts the wipe
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

    // MARK: - What gets erased

    /// A tight, scannable inventory of what the wipe removes — real
    /// structure (a `UniCard` of rows) instead of prose, so the scope
    /// reads at a glance. Each row is one category, leading SF Symbol +
    /// label, no decoration.
    private var erasedList: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                erasedRow(symbol: "wallet.bifold", label: "Every wallet")
                UniDivider()
                erasedRow(symbol: "key.fill", label: "Every encrypted seed and key")
                UniDivider()
                erasedRow(symbol: "chart.line.uptrend.xyaxis", label: "Every cached balance and price")
                UniDivider()
                erasedRow(symbol: "slider.horizontal.3", label: "Every preference and setting")
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
}
