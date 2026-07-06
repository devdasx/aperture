import SwiftUI

enum OpenSourceSheetDesign: String, CaseIterable, Identifiable {
    case compactAudit
    case trustStatement
    case technicalReceipt

    var id: String { rawValue }

    var settingsTitle: LocalizedStringKey {
        switch self {
        case .compactAudit: return "Sheet design 1"
        case .trustStatement: return "Sheet design 2"
        case .technicalReceipt: return "Sheet design 3"
        }
    }

    var settingsSubtitle: LocalizedStringKey {
        switch self {
        case .compactAudit: return "Compact audit"
        case .trustStatement: return "Trust statement"
        case .technicalReceipt: return "Technical receipt"
        }
    }
}

struct OpenSourceSheetDesignPreview: View {
    let design: OpenSourceSheetDesign

    @Environment(\.openURL) private var openURL

    private let repositoryURL: URL = URL(string: "https://github.com/devdasx/aperture")!

    var body: some View {
        UniSheet(title: "Open source") {
            switch design {
            case .compactAudit:
                compactAudit
            case .trustStatement:
                trustStatement
            case .technicalReceipt:
                technicalReceipt
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(
                    title: "View on GitHub",
                    variant: .primary,
                    systemImage: "arrow.up.right.square"
                ) {
                    openURL(repositoryURL)
                }
                .accessibilityLabel(Text("View source code on GitHub"))
            }
        }
    }

    private var compactAudit: some View {
        VStack(alignment: .leading, spacing: UniSpacing.l) {
            HStack(alignment: .top, spacing: UniSpacing.m) {
                heroMark(systemImage: "checkmark.seal.fill", size: UniSpacing.xxl)

                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    UniTitle(
                        text: "Readable. Auditable. Local.",
                        color: UniColors.Text.primary
                    )
                    UniBody(
                        text: "Aperture's source code is public, so the wallet's key generation, seed derivation, and privacy boundary can be checked directly.",
                        color: UniColors.Text.secondary
                    )
                }
            }

            UniCard {
                VStack(alignment: .leading, spacing: UniSpacing.m) {
                    compactAuditRow(
                        systemImage: "key.fill",
                        title: "Keys",
                        detail: "BIP-39 entropy and checksum are generated in Swift."
                    )
                    UniDivider()
                    compactAuditRow(
                        systemImage: "lock.iphone",
                        title: "Seed",
                        detail: "PBKDF2-HMAC-SHA512 with 2048 iterations."
                    )
                    UniDivider()
                    compactAuditRow(
                        systemImage: "eye.slash.fill",
                        title: "Privacy",
                        detail: "No accounts, servers, or balance analytics."
                    )
                }
            }
        }
    }

    private var trustStatement: some View {
        VStack(spacing: UniSpacing.l) {
            VStack(spacing: UniSpacing.m) {
                heroMark(systemImage: "lock.shield.fill", size: UniSpacing.xxxl)

                VStack(spacing: UniSpacing.s) {
                    UniLargeTitle(
                        text: "Verify the wallet, not the promise.",
                        alignment: .center
                    )
                    UniBody(
                        text: "The repository shows how Aperture creates keys, derives the seed, and keeps wallet data on this iPhone.",
                        alignment: .center,
                        color: UniColors.Text.secondary
                    )
                }
            }

            HStack(spacing: UniSpacing.xs) {
                trustPill(systemImage: "curlybraces", title: "Public code")
                trustPill(systemImage: "iphone", title: "Local keys")
                trustPill(systemImage: "network.slash", title: "No servers")
            }

            UniCard {
                VStack(alignment: .leading, spacing: UniSpacing.m) {
                    UniHeadline(text: "What the code proves")

                    VStack(alignment: .leading, spacing: UniSpacing.s) {
                        numberedTrustRow(
                            number: "1",
                            title: "Keys start on device",
                            detail: "Entropy and checksum handling are visible in the source."
                        )
                        numberedTrustRow(
                            number: "2",
                            title: "Seed derivation is standard",
                            detail: "The implementation follows BIP-39 PBKDF2-HMAC-SHA512."
                        )
                        numberedTrustRow(
                            number: "3",
                            title: "Aperture cannot custody funds",
                            detail: "There is no account server that can recover or spend for you."
                        )
                    }
                }
            }
        }
    }

    private var technicalReceipt: some View {
        VStack(alignment: .leading, spacing: UniSpacing.l) {
            UniCard(fill: UniColors.Fill.quaternary) {
                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    UniBadge(text: "Audit surface", kind: .neutral, systemImage: "doc.text.magnifyingglass")
                    UniTitle(text: "Open-source verification")
                    UniSubtitle(
                        text: "A concise receipt of the claims this sheet makes and where the repository lets a reviewer verify them."
                    )
                }
            }

            UniCard {
                VStack(spacing: 0) {
                    receiptRow(
                        label: "Repository",
                        value: "github.com/devdasx/aperture",
                        systemImage: "curlybraces"
                    )
                    UniDivider()
                    receiptRow(
                        label: "Key generation",
                        value: "BIP-39 entropy + checksum",
                        systemImage: "key.fill"
                    )
                    UniDivider()
                    receiptRow(
                        label: "Seed derivation",
                        value: "PBKDF2-HMAC-SHA512, 2048",
                        systemImage: "lock.iphone"
                    )
                    UniDivider()
                    receiptRow(
                        label: "Custody boundary",
                        value: "No account server",
                        systemImage: "eye.slash.fill"
                    )
                }
            }

            UniBody(
                text: "This design treats the sheet like a technical receipt: compact, scannable, and explicit about each verification claim.",
                color: UniColors.Text.secondary
            )
        }
    }

    private func compactAuditRow(
        systemImage: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniBody(text: title, color: UniColors.Text.primary, emphasized: true)
                UniSubtitle(text: detail)
            }
        }
    }

    private func numberedTrustRow(
        number: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text(verbatim: number)
                .font(UniTypography.caption1.weight(.bold))
                .foregroundStyle(UniColors.Button.Primary.label)
                .frame(width: UniSpacing.l, height: UniSpacing.l)
                .background(
                    Circle()
                        .fill(UniColors.Button.Primary.tint)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniBody(text: title, color: UniColors.Text.primary, emphasized: true)
                UniSubtitle(text: detail)
            }
        }
    }

    private func receiptRow(
        label: LocalizedStringKey,
        value: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniCaption(text: label, color: UniColors.Text.tertiary)
                UniBody(text: value, color: UniColors.Text.primary, emphasized: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, UniSpacing.s)
    }

    private func trustPill(
        systemImage: String,
        title: LocalizedStringKey
    ) -> some View {
        VStack(spacing: UniSpacing.xxs) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .accessibilityHidden(true)
            UniCaption(text: title, alignment: .center, color: UniColors.Text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UniSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                .fill(UniColors.Card.background)
        )
    }

    private func heroMark(systemImage: String, size: CGFloat) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Brand.mark)
            .accessibilityHidden(true)
    }
}

#Preview("Compact Audit") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            OpenSourceSheetDesignPreview(design: .compactAudit)
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
}

#Preview("Trust Statement") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            OpenSourceSheetDesignPreview(design: .trustStatement)
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
}

#Preview("Technical Receipt") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            OpenSourceSheetDesignPreview(design: .technicalReceipt)
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
}
