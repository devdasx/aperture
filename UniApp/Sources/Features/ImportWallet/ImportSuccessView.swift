import SwiftUI

/// **Import success — the terminal step of every import flow.** Replaces
/// the post-commit "scanning" wait (the wallet's first refresh now runs
/// in the background while this screen is up) with a branded result, one
/// per import type. Two layouts, per the design handoff:
///
/// - **Key-holding** (recovery phrase / private key / WIF): a green
///   success seal with a drawn check, "Wallet imported" / "Key imported",
///   the wallet card with a rename pencil, the networks the key actually
///   covers, and an in-card self-custody / scope note.
/// - **Watch-only**: a blue eye seal, "Watch-only", the wallet card with
///   the watch badge (no rename), the watched networks, and an in-card
///   view-only note. No "secured on-device" copy.
///
/// **Honesty (Rule #16).** The network row reads the wallet's REAL
/// persisted chains. An EVM key/address fans out to every EVM chain at
/// import time (`ImportWalletState`), so "EVM networks" shows the genuine
/// set the wallet now tracks — never an aspirational list.
///
/// **One CTA.** A single primary "Continue to wallet" button fires
/// `onContinue`, which dismisses the whole import cover onto the wallet.
struct ImportSuccessView: View {
    let walletId: UUID
    let result: ImportResult
    let onContinue: () -> Void
    /// `true` when this same screen terminates the wallet-CREATE flow rather
    /// than an import (2026-06-20 user direction — the create success must
    /// match the import success exactly). Only the copy changes ("created"
    /// vs "imported"); the layout, seal, card and CTA are identical.
    var isCreated: Bool = false
    /// Gates the "Continue to wallet" CTA. The create flow persists in the
    /// background while this screen is already up, so it passes `false` until
    /// the wallet is saved — the user can't leave onto a not-yet-saved wallet.
    /// Imports are persisted before this screen, so they leave it `true`.
    var isContinueEnabled: Bool = true

    @StateObject private var databaseSnapshot = DatabaseSnapshotObservation()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sealScale: CGFloat = 0.55
    @State private var sealOpacity: CGFloat = 0
    @State private var glyphProgress: CGFloat = 0
    @State private var isShowingRename = false
    @State private var renameDraft = ""

    private var wallets: [WalletRecord] {
        databaseSnapshot.wallets
    }

    private var wallet: WalletRecord? { wallets.first { $0.id == walletId } }

    /// Distinct chains the wallet actually holds, in canonical order.
    private var networks: [SupportedChain] {
        guard let wallet else { return [] }
        var seen = Set<String>()
        var ordered: [SupportedChain] = []
        for chain in SupportedChain.allCases {
            for address in wallet.addresses where address.chainRaw == chain.rawValue {
                if seen.insert(chain.rawValue).inserted { ordered.append(chain) }
                break
            }
        }
        return ordered
    }

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        successMark
                            .padding(.top, UniSpacing.l)
                            .padding(.bottom, UniSpacing.l)
                        Text(headline)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, UniSpacing.xs)
                        Text(verbatim: lede)
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                            .padding(.bottom, UniSpacing.l)
                        walletCard
                    }
                    .padding(.horizontal, UniSpacing.l)
                    .frame(maxWidth: .infinity)
                }
                cta
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: animateSeal)
        .alert("Rename wallet", isPresented: $isShowingRename) {
            TextField("Wallet name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { commitRename() }
        } message: {
            Text("Choose a name for this wallet.")
        }
    }

    // MARK: - Success mark

    private var successMark: some View {
        ZStack {
            // Soft radial halo behind the disc.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [accentSoftColor, .clear]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 82
                    )
                )
                .frame(width: 164, height: 164)
                .opacity(sealOpacity)

            // Accent disc.
            Circle()
                .fill(accentColor)
                .frame(width: 112, height: 112)
                .scaleEffect(sealScale)
                .opacity(sealOpacity)

            // Glyph — drawn check (key-holding) or eye (watch-only).
            glyph
                .frame(width: 112, height: 112)
                .scaleEffect(sealScale)
        }
        .frame(width: 128, height: 128)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if isWatchOnly {
            Image(systemName: "eye.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(glyphProgress)
                .scaleEffect(0.6 + 0.4 * glyphProgress)
        } else {
            SealCheck()
                .trim(from: 0, to: glyphProgress)
                .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
        }
    }

    private func animateSeal() {
        if reduceMotion {
            sealScale = 1; sealOpacity = 1; glyphProgress = 1
            UniHapticEngine.shared.play(.success)
            return
        }
        UniHapticEngine.shared.play(.signature(.irisSettle))
        withAnimation(.spring(response: 0.56, dampingFraction: 0.62)) {
            sealScale = 1
            sealOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.4).delay(0.18)) {
            glyphProgress = 1
        }
        // Success haptic when the seal has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) {
            UniHapticEngine.shared.play(.success)
        }
    }

    // MARK: - Wallet card

    private var walletCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UniSpacing.s) {
                if let wallet {
                    WalletAvatar(spec: wallet.avatarSpec, size: .preview, walletId: walletId)
                } else {
                    Circle().fill(UniColors.Background.tertiary).frame(width: 56, height: 56)
                }
                Text(verbatim: wallet?.name ?? "")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: UniSpacing.s)
                if !isWatchOnly {
                    Button {
                        renameDraft = wallet?.name ?? ""
                        isShowingRename = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(UniColors.Icon.secondary)
                            .frame(width: 34, height: 34)
                            .background(UniColors.Background.tertiary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Rename wallet"))
                }
            }

            Text(networkLabel)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(UniColors.Text.tertiary)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.s)

            networkRow

            explanationRow
                .padding(.top, UniSpacing.m)
        }
        .padding(UniSpacing.m)
        .background(
            UniColors.Background.secondary,
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
    }

    private var networkRow: some View {
        let shown = Array(networks.prefix(networkCap))
        let extra = networks.count - shown.count
        return HStack(spacing: -9) {
            ForEach(Array(shown.enumerated()), id: \.element.rawValue) { index, chain in
                networkIcon(chain)
                    .zIndex(Double(shown.count - index))
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
                    .padding(.leading, 13)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func networkIcon(_ chain: SupportedChain) -> some View {
        CoinMark(chain: chain, tokenSymbol: chain.ticker)
        .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
        .overlay(Circle().stroke(UniColors.Background.secondary, lineWidth: 2.5))
        .accessibilityLabel(Text(verbatim: chain.displayName))
    }

    private var explanationRow: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: explanationIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 26, height: 26)
                .background(UniColors.Background.tertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(verbatim: explanationText)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, UniSpacing.m)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(UniColors.Separator.regular)
                .frame(height: 1)
        }
    }

    // MARK: - CTA

    private var cta: some View {
        UniButton(title: "Continue to wallet", variant: .primary, isEnabled: isContinueEnabled) {
            onContinue()
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.m)
    }

    // MARK: - Rename

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let wallet else { return }
        try? WalletRepository(database: AppDatabase.shared).renameWallet(id: wallet.id, to: trimmed)
    }

    // MARK: - Variant copy / scoping

    private var isWatchOnly: Bool {
        if case .watchOnly = result { return true }
        return false
    }

    private var isEVMKey: Bool {
        switch result {
        case .privateKey(let chain): return chain.family == .evm
        case .watchOnly(let chain): return chain.family == .evm
        case .mnemonic: return false
        }
    }

    /// Brand seal colour — green for key-holding (secured), blue for
    /// watch-only (view-only). Sourced from the `UniColors.Seal` roles
    /// (Rule #4 §B keeps the hex in `UniColors`).
    private var accentColor: Color {
        isWatchOnly ? UniColors.Seal.watching(colorScheme) : UniColors.Seal.secured(colorScheme)
    }

    private var accentSoftColor: Color {
        accentColor.opacity(colorScheme == .dark ? 0.22 : 0.18)
    }

    private var headline: LocalizedStringKey {
        switch result {
        case .mnemonic:   return isCreated ? "Wallet created" : "Wallet imported"
        case .privateKey: return "Key imported"
        case .watchOnly:  return "Watch-only"
        }
    }

    private var lede: String {
        switch result {
        case .mnemonic:
            if isCreated {
                return String(localized: "Your recovery phrase is saved and your keys are secured on this device.")
            }
            return String(localized: "Your recovery phrase was verified and your keys are now secured on this device.")
        case .privateKey(let chain):
            if chain.family == .evm {
                return String(localized: "We detected an EVM key. Its account is ready across all EVM networks, secured on this device.")
            }
            return String(
                format: String(localized: "We detected a %@ key. Its account is ready on %@, secured on this device."),
                chain.displayName, chain.displayName
            )
        case .watchOnly(let chain):
            if chain.family == .evm {
                return String(localized: "You'll follow this address's balance and activity across EVM networks.")
            }
            return String(
                format: String(localized: "You'll follow this address's balance and activity on %@."),
                chain.displayName
            )
        }
    }

    private var networkLabel: LocalizedStringKey {
        switch result {
        case .mnemonic: return "Networks"
        case .privateKey: return isEVMKey ? "EVM networks" : "Network"
        case .watchOnly: return "Network"
        }
    }

    /// How many icons to show before the "+N" overflow. The full set fits
    /// for a single chain or the EVM set; only the multi-chain mnemonic
    /// import overflows.
    private var networkCap: Int {
        switch result {
        case .mnemonic: return 10
        default: return networks.count
        }
    }

    private var explanationIcon: String {
        switch result {
        case .mnemonic:   return "checkmark.shield"
        case .privateKey: return "info.circle"
        case .watchOnly:  return "lock"
        }
    }

    private var explanationText: String {
        switch result {
        case .mnemonic:
            return String(localized: "Keys secured on-device. Aperture is self-custodial — your phrase never leaves this phone and is never sent to a server.")
        case .privateKey(let chain):
            if chain.family == .evm {
                return String(localized: "EVM key detected. The same address works on Ethereum and every EVM network. Non-EVM chains aren't covered by this key.")
            }
            return String(
                format: String(localized: "Single-chain key. This key belongs to %@ and signs only there. Import a recovery phrase for a multi-chain wallet."),
                chain.displayName
            )
        case .watchOnly:
            return String(localized: "View-only. Send and signing are disabled until you import this address's keys.")
        }
    }
}

// MARK: - Seal check shape

/// The success check, drawn in the handoff's 128-unit coordinate space
/// (M44,65 → L58,79 → L86,49) scaled to the rendered frame, so `.trim`
/// can animate the stroke on.
private struct SealCheck: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 128
        var path = Path()
        path.move(to: CGPoint(x: 44 * s, y: 65 * s))
        path.addLine(to: CGPoint(x: 58 * s, y: 79 * s))
        path.addLine(to: CGPoint(x: 86 * s, y: 49 * s))
        return path
    }
}
