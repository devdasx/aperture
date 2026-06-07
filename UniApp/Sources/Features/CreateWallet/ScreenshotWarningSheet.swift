import SwiftUI

/// Presented when the user takes a screenshot while the recovery phrase
/// is on screen. Names the risk honestly (Rule #16 §A.6) and gives the
/// user the agency to either (a) generate a new phrase — making the
/// screenshot they just took harmless — or (b) keep the current phrase
/// at the user's own risk.
///
/// **Sheet shape.** Uses the unified `UniSheet` shell.
struct ScreenshotWarningSheet: View {
    let onRegeneratePhrase: () -> Void
    let onKeepScreenshot: () -> Void

    /// Toggle for the nested open-source sheet (Rule #16 §A.4).
    @State private var isShowingOpenSource: Bool = false

    var body: some View {
        UniSheet(title: "Screenshot detected") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                bodyCopy
                betterMethods
                openSourceFootnote
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Generate new phrase", variant: .primary) {
                        onRegeneratePhrase()
                    }
                    UniButton(title: "Keep current phrase", variant: .secondary) {
                        onKeepScreenshot()
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
                .foregroundStyle(UniColors.Status.warningForeground)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var bodyCopy: some View {
        UniBody(
            text: "Saving your recovery phrase as a screenshot is risky. Screenshots sync to iCloud, appear in your photo library and Recents, and can be read by anyone with your unlocked phone.",
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
