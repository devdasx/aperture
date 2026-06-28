import SwiftUI

/// Presented when the user takes a screenshot while the recovery phrase
/// is on screen. Names the risk honestly (Rule #16 §A.6) and gives the
/// user the agency to either (a) generate a new phrase — making the
/// screenshot they just took harmless — or (b) keep the current phrase
/// at the user's own risk.
///
/// **Sheet shape.** Uses the unified `UniSheet` shell.
struct ScreenshotWarningSheet: View {
    /// Wallet **creation** passes this so the user can invalidate the
    /// just-screenshotted phrase by generating fresh entropy. Wallet
    /// **export** (an existing, funded wallet) leaves it `nil` —
    /// regenerating there would mean a different wallet, not a safer one —
    /// so the sheet collapses to a single acknowledge button.
    var onRegeneratePhrase: (() -> Void)? = nil
    let onKeepScreenshot: () -> Void

    /// Which secret was on screen — drives the body wording so the sheet
    /// reads correctly whether it fired over a recovery phrase or a single
    /// chain's private key (2026-06-19 user direction).
    enum Secret {
        case recoveryPhrase
        case privateKey

        var bodyCopy: LocalizedStringKey {
            switch self {
            case .recoveryPhrase:
                return "Saving your recovery phrase as a screenshot is risky. Screenshots sync to iCloud, appear in your photo library and Recents, and can be read by anyone with your unlocked phone."
            case .privateKey:
                return "Saving your private key as a screenshot is risky. Screenshots sync to iCloud, appear in your photo library and Recents, and can be read by anyone with your unlocked phone."
            }
        }
    }
    var secret: Secret = .recoveryPhrase

    /// Toggle for the nested open-source sheet (Rule #16 §A.4).
    @State private var isShowingOpenSource: Bool = false

    var body: some View {
        UniSheet(title: "Screenshot detected") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                bodyCopy
                betterMethods
                // The open-source footnote explains how recovery *phrases*
                // are generated — only relevant in the phrase context.
                if case .recoveryPhrase = secret {
                    openSourceFootnote
                }
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    if let onRegeneratePhrase {
                        UniButton(title: "Generate new phrase", variant: .primary) {
                            onRegeneratePhrase()
                        }
                        UniButton(title: "Keep current phrase", variant: .secondary) {
                            onKeepScreenshot()
                        }
                    } else {
                        // Export of an existing wallet — only an acknowledge.
                        UniButton(title: "I understand", variant: .primary) {
                            onKeepScreenshot()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingOpenSource) {
            OpenSourceSheet()
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Feedback.Warning.foreground)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var bodyCopy: some View {
        UniBody(
            text: secret.bodyCopy,
            color: UniColors.Text.secondary
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var betterMethods: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniFeatureRow(
                    systemImage: "pencil.line",
                    title: "Write it on paper. Keep the paper offline."
                )
                UniDivider()
                UniFeatureRow(
                    systemImage: "lock.shield",
                    title: "Use a hardware security key."
                )
                UniDivider()
                UniFeatureRow(
                    systemImage: "creditcard.and.123",
                    title: "Stamp it into metal for fire and water survival."
                )
            }
        }
    }

    private var openSourceFootnote: some View {
        Button {
            isShowingOpenSource = true
        } label: {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .regular))
                Text("All of this is open source — see how recovery phrases are generated.")
                    .font(UniTypography.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(UniColors.Text.tertiary)
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Opens a sheet describing how this recovery phrase was generated"))
    }
}

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ScreenshotWarningSheet(
                onRegeneratePhrase: {},
                onKeepScreenshot: {}
            )
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ScreenshotWarningSheet(
                onRegeneratePhrase: {},
                onKeepScreenshot: {}
            )
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .preferredColorScheme(.dark)
}
