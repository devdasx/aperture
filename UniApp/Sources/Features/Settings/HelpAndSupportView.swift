import SwiftUI

/// Help & Support — pushed from the Settings root via
/// `SettingsDestination.help`. Per the jony-ive 2026-06-05 design audit,
/// four sections: Documentation & repository, Report & request,
/// Community, and a footer-only Boundary statement (Rule #16 §A.5
/// anchor — the load-bearing element of the screen).
///
/// **Honesty (Rule #2 §A.7 + Rule #16).** Aperture has no servers, no
/// support team, no recovery path. The Boundary statement says so
/// plainly — that is the sentence that protects a phishing-attempt-in-
/// progress user. No invented support inbox, no "live chat", no
/// telemetry-opt-out (we never send telemetry).
///
/// **External links.** Every row that leaves the app uses SwiftUI's
/// native `Link(destination:)` which iOS routes to Safari (Rule #3 —
/// no in-app browser). A trailing `arrow.up.right` glyph signals the
/// external destination — the same convention iOS Settings uses for
/// "leaves the app" rows.
struct HelpAndSupportView: View {
    /// Canonical Aperture URLs. Local to this view to avoid premature
    /// extraction; if a third surface needs them, lift to a shared
    /// `AppLinks` enum.
    private let readmeURL = URL(string: "https://github.com/devdasx/aperture#readme")!
    private let repositoryURL = URL(string: "https://github.com/devdasx/aperture")!
    private let bugReportURL = URL(string: "https://github.com/devdasx/aperture/issues/new?labels=bug")!
    private let featureRequestURL = URL(string: "https://github.com/devdasx/aperture/issues/new?labels=enhancement")!
    private let discussionsURL = URL(string: "https://github.com/devdasx/aperture/discussions")!

    var body: some View {
        List {
            documentationSection
            reportSection
            communitySection
            boundarySection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Help & Support"))
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Section 1: documentation

    private var documentationSection: some View {
        Section {
            externalLinkRow(
                url: readmeURL,
                systemImage: "book.closed",
                title: "Read documentation"
            )
            externalLinkRow(
                url: repositoryURL,
                systemImage: "chevron.left.forwardslash.chevron.right",
                title: "View source on GitHub"
            )
        } footer: {
            Text("Aperture is open source. Every claim above is verifiable in the code.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }

    // MARK: - Section 2: report & request

    private var reportSection: some View {
        Section {
            externalLinkRow(
                url: bugReportURL,
                systemImage: "ladybug",
                title: "Report a bug"
            )
            externalLinkRow(
                url: featureRequestURL,
                systemImage: "lightbulb",
                title: "Request a feature"
            )
        }
    }

    // MARK: - Section 3: community

    private var communitySection: some View {
        Section {
            externalLinkRow(
                url: discussionsURL,
                systemImage: "person.2",
                title: "Join the discussion"
            )
        }
    }

    // MARK: - Section 4: boundary statement (Rule #16 §A.5)

    private var boundarySection: some View {
        Section {
            // Footer-only section — no rows. The honest limit goes here.
            EmptyView()
        } footer: {
            Text("Aperture has no servers, no support team, and no way to recover your wallet for you. Nobody from Aperture will ever message you, email you, or ask for your recovery phrase. If someone claims to be Aperture support, they are not.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Row primitive

    @ViewBuilder
    private func externalLinkRow(
        url: URL,
        systemImage: String,
        title: LocalizedStringKey
    ) -> some View {
        Link(destination: url) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)

                Text(title)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, UniSpacing.xxs)
            .contentShape(Rectangle())
        }
        .listRowBackground(UniColors.Background.secondary)
    }
}

#Preview("Light") {
    NavigationStack {
        HelpAndSupportView()
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        HelpAndSupportView()
    }
    .preferredColorScheme(.dark)
}
