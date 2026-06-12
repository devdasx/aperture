import SwiftUI

// MARK: - Recovery phrase guide sheet (Rule #18 Part C)

/// "What's a recovery phrase?" — the canonical guide-sheet shape from
/// Rule #18 §B. Presented from `MnemonicEntryView`'s info-circle
/// toolbar button.
struct RecoveryPhraseGuideSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "What's a recovery phrase?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                explainerBody
                exampleBlock
                howToUse
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) {
                onDismiss()
            }
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var explainerBody: some View {
        UniBody(
            text: "A recovery phrase is twelve or twenty-four plain English words. Together they are the seed your wallet was generated from.",
            color: UniColors.Text.primary
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exampleBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(
                text: "Example only — never type this as your real phrase.",
                color: UniColors.Text.tertiary
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
                .font(UniTypography.subheadline.monospaced())
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(UniSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
        }
    }

    private var howToUse: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniBody(
                text: "Each word is one of 2,048 standard words. Aperture checks every word you type against that list.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Type or paste your phrase, separating words with spaces. Order matters — the same words in a different order are a different wallet.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apertureRole: some View {
        UniBody(
            text: "Aperture only uses your phrase on this iPhone to derive your accounts. It never leaves your device.",
            color: UniColors.Text.secondary
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Private key guide sheet (Rule #18 Part C)

struct PrivateKeyGuideSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "What's a private key?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                explainerBody
                exampleBlock
                howToUse
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) {
                onDismiss()
            }
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var explainerBody: some View {
        UniBody(
            text: "A private key is the secret number that controls one account on one chain. It usually looks like a long string of letters and digits.",
            color: UniColors.Text.primary
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exampleBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(
                text: "Example only — never type this as your real key.",
                color: UniColors.Text.tertiary
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "0x0000000000000000000000000000000000000000000000000000000000000001")
                .font(UniTypography.caption1.monospaced())
                .foregroundStyle(UniColors.Text.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(UniSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
        }
    }

    private var howToUse: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniBody(
                text: "Unlike a recovery phrase, one private key unlocks just one chain. Your other chains stay outside Aperture unless you import their keys too.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Paste your key — Aperture never asks you to type it character by character.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apertureRole: some View {
        UniBody(
            text: "Your key never leaves this iPhone. Aperture does not send it anywhere.",
            color: UniColors.Text.secondary
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Watch-only guide sheet (Rule #18 Part C — T-034)

struct WatchOnlyGuideSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "What does watch-only mean?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                explainerBody
                exampleBlock
                howToUse
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) {
                onDismiss()
            }
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "eye.fill")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var explainerBody: some View {
        UniBody(
            text: "A watch-only wallet shows you what an address owns and what it has done — without ever holding the keys.",
            color: UniColors.Text.primary
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exampleBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(
                text: "Example only — not a real address.",
                color: UniColors.Text.tertiary
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "bc1qexample…example…example")
                .font(UniTypography.subheadline.monospaced())
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(UniSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
        }
    }

    private var howToUse: some View {
        UniBody(
            text: "Paste one or more addresses you already own. For Bitcoin, Litecoin, or Dogecoin you can also paste an extended public key, and Aperture will derive the wallet's receive addresses for you.",
            color: UniColors.Text.secondary
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var apertureRole: some View {
        UniBody(
            text: "Aperture reads balances and transactions on-chain. It cannot sign, send, or move funds — that requires the private key, which a watch-only wallet does not have.",
            color: UniColors.Text.secondary
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - "Is this really your key?" security warning sheet

/// Presented when the user taps Recovery phrase or Private key in the
/// method picker, unless they've previously chosen "Don't show again".
/// Names the social-engineering risk plainly.
struct ImportSecurityWarningSheet: View {
    /// Fires when the user taps "I understand". The `Bool` carries
    /// whether the user also wants to suppress future warnings.
    let onProceed: (_ hideNextTime: Bool) -> Void

    @State private var hideNextTime: Bool = false

    var body: some View {
        UniSheet(title: "Is this really your key?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                copyBlock
                suppressToggle
            }
        } actions: {
            UniButton(title: "I understand", variant: .primary) {
                onProceed(hideNextTime)
            }
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniHeadline(
                text: "Only import a wallet that is yours.",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "If someone sent you a recovery phrase or private key, that is a scam. The sender keeps a copy and can drain the wallet the moment you fund it.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "This includes phrases shared in chat, on social media, in support emails, by \"wallet recovery\" services, or generated by a website. There is no legitimate reason another person ever gives you a key.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Aperture cannot tell whose key you are importing. Only you can. Continue only if this key is yours.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suppressToggle: some View {
        UniToggle(isOn: $hideNextTime) {
            UniBody(
                text: "Don't show this warning again",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .tint(UniColors.Tint.accent)
    }
}

// MARK: - Leaked-seed warning sheet

/// Presented when the user tries to import a known-publicly-leaked
/// mnemonic or private key. Two CTAs — destructive primary "Choose a
/// different wallet" and restrained tertiary "Use it anyway" (honesty
/// over paternalism — a dev intentionally using the Hardhat test seed
/// for testnet exploration should be able to proceed).
struct LeakedSeedWarningSheet: View {
    enum Kind { case mnemonic, privateKey }

    let kind: Kind
    let onChooseDifferent: () -> Void
    let onUseAnyway: () -> Void

    var body: some View {
        UniSheet(title: titleKey) {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                copyBlock
            }
        } actions: {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Choose a different wallet", variant: .destructive) {
                        onChooseDifferent()
                    }
                    UniButton(title: "Use it anyway", variant: .tertiary) {
                        onUseAnyway()
                    }
                }
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        switch kind {
        case .mnemonic:   return "This phrase is publicly known"
        case .privateKey: return "This key is publicly known"
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Status.warningForeground)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniHeadline(
                text: kind == .mnemonic ? "Many people know this phrase." : "Many people know this key.",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "It appears in public documentation, tutorials, or test environments. Anyone who reads those can spend any funds at the addresses it generates.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "If you copied this from a guide or tutorial, this is not your wallet. Use the recovery phrase from the wallet you actually own.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniFootnote(
                text: "If you are testing on a development network and want to use it on purpose, you can still proceed.",
                alignment: .leading,
                color: UniColors.Text.tertiary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
