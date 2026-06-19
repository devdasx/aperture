import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// **Export Recovery Phrase (Flow A) and Export Private Key (Flow B).**
/// Full-screen flows that replace the old bottom-sheet reveals
/// (2026-06-19 design handoff). Auth (the unified passcode / Face ID
/// screen) runs in `WalletDetailView` BEFORE these present, so there is
/// no in-flow auth step.
///
/// - **Flow A** (`ExportRecoveryPhraseFlow`): Warn → Reveal. No verify
///   step — this is export, not first-time backup; the user already owns
///   the wallet.
/// - **Flow B** (`ExportPrivateKeyFlow`): Pick network → Warn (per-chain)
///   → Reveal (per-chain, with a QR sheet). The chosen chain scopes the
///   warning + the key format.
///
/// **Security (handoff "build requirements").** Secrets render only from
/// the Keychain-backed vault / scoped key derivation, decrypted off-main.
/// The phrase/key stays blurred until an explicit tap and re-blurs when
/// the app backgrounds. Copy auto-clears the clipboard after 20s with a
/// visible countdown. Nothing is logged or sent anywhere.

// MARK: - Chain entry

/// One chain the wallet holds + its address — the picker's row data and
/// the reveal's derivation input. Sendable value (the old
/// `ChainKeysRevealSheet.ChainEntry` replacement).
struct ExportChainEntry: Hashable, Sendable {
    let chain: SupportedChain
    let address: String
}

// MARK: - Secure clipboard

/// Writes a secret to the pasteboard with a 20-second OS-managed
/// expiration — the only honest way to put a phrase / key on the
/// clipboard (matches `RecoveryPhraseView.copyPhrase`).
enum ExportClipboard {
    static let clearSeconds: Int = 20

    static func copy(_ secret: String) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: secret]],
            options: [.expirationDate: Date().addingTimeInterval(TimeInterval(clearSeconds))]
        )
        #endif
    }
}

// MARK: - Flow A: Export Recovery Phrase

struct ExportRecoveryPhraseFlow: View {
    let walletId: UUID
    let walletName: String
    let onClose: () -> Void

    @State private var isShowingReveal = false

    var body: some View {
        NavigationStack {
            ExportWarnScreen(
                title: "Your phrase is the key to everything",
                lede: "Your recovery phrase restores every account on every network. Treat it like the keys to a vault.",
                rows: [
                    .init(icon: "hand.raised.fill",
                          lead: "Never share it",
                          detail: "Anyone with these words can take all your funds. No real support team will ever ask for them."),
                    .init(icon: "wifi.slash",
                          lead: "Keep it offline",
                          detail: "Write it on paper and store it somewhere safe. Don't screenshot it or save it to the cloud."),
                    .init(icon: "exclamationmark.arrow.circlepath",
                          lead: "There's no reset",
                          detail: "Aperture can't recover this phrase for you. Lose it with no copy and the funds are gone.")
                ],
                revealTitle: "Reveal recovery phrase",
                onReveal: { isShowingReveal = true },
                onCancel: onClose
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
            .navigationDestination(isPresented: $isShowingReveal) {
                RecoveryPhraseRevealScreen(walletId: walletId, walletName: walletName, onDone: onClose)
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
    }
}

// MARK: - Flow A reveal

private struct RecoveryPhraseRevealScreen: View {
    let walletId: UUID
    let walletName: String
    let onDone: () -> Void

    @State private var words: [String] = []
    @State private var loadError: String?
    @State private var revealed = false
    @State private var copied = false
    @State private var isShowingQR = false
    @State private var isShowingBackup = false
    @State private var isShowingScreenshotWarning = false
    /// Gates the screenshot notification to when this screen is actually on
    /// top — the notification is global and keeps firing under pushed/
    /// presented screens otherwise.
    @State private var isVisible = false

    /// "Write these 12 words down…" — the count is the wallet's real word
    /// count (12 or 24), never hard-coded (2026-06-19 user direction).
    private var subtitle: String {
        String(
            format: String.apertureLocalized("Write these %lld words down in order and keep them somewhere only you can reach."),
            Int64(words.count)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    VStack(alignment: .leading, spacing: UniSpacing.xs) {
                        Text("Your recovery phrase")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                        if !words.isEmpty && loadError == nil {
                            Text(verbatim: subtitle)
                                .font(UniTypography.subheadline)
                                .foregroundStyle(UniColors.Text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, UniSpacing.s)

                    if let loadError {
                        UniBody(text: LocalizedStringKey(loadError), alignment: .center, color: UniColors.Status.errorForeground)
                            .padding(.vertical, UniSpacing.xxl)
                    } else if words.isEmpty {
                        UniLoadingState(caption: "Preparing your phrase…")
                            .padding(.vertical, UniSpacing.xxl)
                    } else {
                        ExportRevealGate(revealed: $revealed) {
                            phraseGrid
                        }
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }

            if !words.isEmpty && loadError == nil {
                ExportActionBar(
                    copyTitle: "Copy phrase",
                    doneTitle: "Backup Now",
                    copied: $copied,
                    isRevealed: revealed,
                    onCopy: {
                        ExportClipboard.copy(words.joined(separator: " "))
                    },
                    // "Backup Now" launches the real backup flow (iCloud
                    // encrypted backup or manual verify) against this wallet's
                    // already-decrypted phrase.
                    onDone: { isShowingBackup = true }
                )
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !words.isEmpty && loadError == nil {
                    Button { isShowingQR = true } label: {
                        Image(systemName: "qrcode").font(.system(size: 17, weight: .regular))
                    }
                    .accessibilityLabel(Text("Show QR code"))
                }
            }
        }
        .sheet(isPresented: $isShowingQR) {
            if !words.isEmpty {
                ExportQRSheet(
                    navTitle: String.apertureLocalized("Recovery phrase QR"),
                    caption: "Scan or save your recovery phrase. Anyone who scans it can restore your wallet and take your funds.",
                    payload: words.joined(separator: " ")
                ) {
                    // The app mark centres the phrase QR (there's no single
                    // coin for a whole wallet).
                    Image("LogoCircle").resizable().scaledToFit()
                }
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationBackground(UniColors.Background.primary)
            }
        }
        .sheet(isPresented: $isShowingScreenshotWarning) {
            // Same warning sheet as wallet creation, in export mode (no
            // "generate new phrase" — this wallet already exists). We do NOT
            // block the screenshot; per the export security model the user
            // is always allowed to capture their own backup.
            ScreenshotWarningSheet(
                onKeepScreenshot: { isShowingScreenshotWarning = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingBackup) {
            WalletBackupFlow(
                walletId: walletId,
                walletName: walletName,
                words: words,
                onClose: {
                    isShowingBackup = false
                    onDone()
                }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .task { await load() }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            words = []
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard isVisible else { return }
            isShowingScreenshotWarning = true
        }
    }

    /// 12/24 words in ONE grouped container — two columns, subtle index
    /// numbers, hairline dividers (no per-word cards). Forced LTR so the
    /// ordinal reading order never flips in an RTL locale.
    private var phraseGrid: some View {
        let rowsCount = (words.count + 1) / 2
        return VStack(spacing: 0) {
            ForEach(0..<rowsCount, id: \.self) { r in
                HStack(spacing: 0) {
                    wordCell(index: r, in: 0)
                    Rectangle().fill(UniColors.Separator.regular).frame(width: 1)
                    wordCell(index: r + rowsCount, in: 1)
                }
                if r < rowsCount - 1 {
                    Rectangle().fill(UniColors.Separator.regular).frame(height: 1)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
        // No border (2026-06-19 user direction) — the soft fill alone
        // defines the card.
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func wordCell(index: Int, in column: Int) -> some View {
        if index < words.count {
            HStack(spacing: UniSpacing.xs) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 13, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .frame(width: 24, alignment: .leading)
                Text(words[index])
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Odd word count — keep the grid square with an empty cell.
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        let id = walletId
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try MnemonicVault.loadMnemonic(for: id) ?? []
            }.value
            words = loaded
            if words.isEmpty {
                loadError = String.apertureLocalized("No phrase is stored for this wallet.")
            }
        } catch {
            loadError = String.apertureLocalized("Could not decrypt the phrase. Try restarting Aperture.")
        }
    }
}

// MARK: - Flow B: Export Private Key

struct ExportPrivateKeyFlow: View {
    let descriptor: WalletDescriptor
    let chains: [ExportChainEntry]
    let onClose: () -> Void

    @State private var path: [ExportKeyStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            PickNetworkScreen(chains: chains) { entry in
                path.append(.warn(entry))
            } onClose: {
                onClose()
            }
            .navigationDestination(for: ExportKeyStep.self) { step in
                switch step {
                case .warn(let entry):
                    ExportWarnScreen(
                        title: "This key controls your \(entry.chain.displayName)",
                        lede: "A private key gives full control of this one account. Anyone who has it can move the funds.",
                        rows: warnRows(for: entry.chain),
                        revealTitle: "Reveal private key",
                        onReveal: { path.append(.reveal(entry)) },
                        onCancel: { if !path.isEmpty { path.removeLast() } }
                    )
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                case .reveal(let entry):
                    KeyRevealScreen(descriptor: descriptor, entry: entry, onDone: onClose)
                }
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
    }

    private func warnRows(for chain: SupportedChain) -> [ExportWarnRow.Model] {
        var rows: [ExportWarnRow.Model] = [
            .init(icon: "hand.raised.fill",
                  lead: "Never share it",
                  detail: "Anyone with this key can take the funds on its address. No real support team will ever ask for it.")
        ]
        if chain.family == .evm {
            rows.append(.init(icon: "square.stack.3d.up.fill",
                              lead: "One key, all EVM chains",
                              detail: "This same key controls this address on Ethereum and every EVM network."))
        }
        rows.append(.init(icon: "wifi.slash",
                          lead: "Keep it offline",
                          detail: "Don't screenshot it or paste it into apps and sites you don't fully trust."))
        return rows
    }
}

/// The two pushed steps of Flow B.
enum ExportKeyStep: Hashable {
    case warn(ExportChainEntry)
    case reveal(ExportChainEntry)
}

// MARK: - Flow B step 1: pick network

private struct PickNetworkScreen: View {
    let chains: [ExportChainEntry]
    let onPick: (ExportChainEntry) -> Void
    let onClose: () -> Void

    @State private var query = ""

    private var filtered: [ExportChainEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chains }
        return chains.filter {
            $0.chain.displayName.lowercased().contains(q) || $0.chain.ticker.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filtered, id: \.self) { entry in
                    Button { onPick(entry) } label: {
                        HStack(spacing: UniSpacing.s) {
                            CoinMark(chain: entry.chain, tokenSymbol: entry.chain.ticker)
                                .frame(width: 36, height: 36)
                            Text(verbatim: entry.chain.displayName)
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)
                            Spacer()
                            Text(verbatim: entry.chain.ticker)
                                .font(UniTypography.subheadline)
                                .foregroundStyle(UniColors.Text.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(UniColors.Icon.tertiary)
                        }
                        .padding(.vertical, UniSpacing.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                }
            } header: {
                Text("Choose the network whose key you want to export.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle("Select network")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search networks"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("Close"))
            }
        }
    }
}

// MARK: - Flow B step 3: key reveal

private struct KeyRevealScreen: View {
    let descriptor: WalletDescriptor
    let entry: ExportChainEntry
    let onDone: () -> Void

    @State private var row: PrivateKeyExport.Row?
    @State private var loaded = false
    @State private var revealed = false
    @State private var copied = false
    @State private var isShowingQR = false
    @State private var isShowingScreenshotWarning = false
    /// Gates the global screenshot notification to when this screen is on top.
    @State private var isVisible = false

    private var keyValue: String? { row?.value }

    /// The honest one-line scope of this key (2026-06-19 user direction):
    /// an EVM key is the same account across every EVM chain; a non-EVM key
    /// controls exactly its own chain's account.
    private var keySubtitle: String {
        if entry.chain.family == .evm {
            return String.apertureLocalized("This single key controls your Ethereum account on every EVM chain. Never share it.")
        }
        return String(
            format: String.apertureLocalized("This single key controls your %@ account. Never share it."),
            entry.chain.displayName
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    VStack(alignment: .leading, spacing: UniSpacing.xs) {
                        Text("\(entry.chain.displayName) private key")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                        Text(verbatim: keySubtitle)
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, UniSpacing.s)

                    if !loaded {
                        UniLoadingState(caption: "Deriving your key…")
                            .padding(.vertical, UniSpacing.xxl)
                    } else if let value = keyValue, let row {
                        ExportRevealGate(revealed: $revealed) {
                            keyPanel(value: value, format: row.format)
                        }
                    } else {
                        UniBody(
                            text: "This key isn't available on this device.",
                            alignment: .center,
                            color: UniColors.Text.tertiary
                        )
                        .padding(.vertical, UniSpacing.xxl)
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }

            if keyValue != nil {
                ExportActionBar(
                    copyTitle: "Copy key",
                    doneTitle: "Done",
                    copied: $copied,
                    isRevealed: revealed,
                    onCopy: { if let v = keyValue { ExportClipboard.copy(v) } },
                    onDone: onDone
                )
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if keyValue != nil {
                    Button { isShowingQR = true } label: {
                        Image(systemName: "qrcode").font(.system(size: 17, weight: .regular))
                    }
                    .accessibilityLabel(Text("Show QR code"))
                }
            }
        }
        .sheet(isPresented: $isShowingQR) {
            if let value = keyValue {
                ExportQRSheet(
                    navTitle: String(format: String.apertureLocalized("%@ key QR"), entry.chain.displayName),
                    caption: "Scan or save this private key. Anyone who scans it gets full control of the account.",
                    payload: value
                ) {
                    // The coin centres the key QR (2026-06-19 user direction).
                    CoinMark(chain: entry.chain, tokenSymbol: entry.chain.ticker)
                }
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationBackground(UniColors.Background.primary)
            }
        }
        .sheet(isPresented: $isShowingScreenshotWarning) {
            // Same warning sheet as the recovery-phrase reveal, in the
            // private-key wording. Screenshots are not blocked — user choice.
            ScreenshotWarningSheet(
                onKeepScreenshot: { isShowingScreenshotWarning = false },
                secret: .privateKey
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .task { await load() }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            row = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard isVisible else { return }
            isShowingScreenshotWarning = true
        }
    }

    private func keyPanel(value: String, format: String) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text("Private key")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(UniColors.Text.tertiary)

            HStack(spacing: UniSpacing.xs) {
                CoinMark(chain: entry.chain, tokenSymbol: entry.chain.ticker)
                    .frame(width: 22, height: 22)
                Text(verbatim: entry.chain.displayName)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            }

            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(UniColors.Text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)
                .environment(\.layoutDirection, .leftToRight)

            Text(verbatim: format)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
        }
        .padding(UniSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
        // No border (2026-06-19 user direction).
    }

    private func load() async {
        let desc = descriptor
        let chain = entry.chain
        let address = entry.address
        let derived = await Task.detached(priority: .userInitiated) {
            PrivateKeyExport.exportAll(wallet: desc, chains: [(chain: chain, address: address)])
        }.value
        row = derived.first
        loaded = true
    }
}

// MARK: - QR sheet (shared by both flows)

/// A QR sheet with a centred mark — the coin for a private key, the app
/// mark for a recovery phrase (2026-06-19 user direction). The mark is a
/// view overlay (the same recipe `ReceiveQRCard` uses); the QR is rendered
/// at error-correction level "H" so the centred plate never defeats a scan.
/// The image saved to Photos is the plain (logo-free) QR — maximally
/// scannable — which is the standard for transferable key/phrase QRs.
private struct ExportQRSheet<Center: View>: View {
    let navTitle: String
    let caption: LocalizedStringKey
    let payload: String
    @ViewBuilder var center: () -> Center

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var qr: UIImage?
    @State private var saveResult: SaveResult?

    private enum SaveResult { case success, failure }

    var body: some View {
        NavigationStack {
            VStack(spacing: UniSpacing.l) {
                Text(caption)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, UniSpacing.l)

                Group {
                    if let qr {
                        Image(uiImage: qr)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .overlay(alignment: .center) { centreMark }
                    } else {
                        UniLoadingState(caption: "Building QR…")
                    }
                }
                .frame(width: 240, height: 240)
                .padding(UniSpacing.m)
                .background(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous).fill(.white))

                if let saveResult {
                    Text(saveResult == .success ? "Saved to Photos." : "Couldn't save. Allow Photos access in Settings.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(saveResult == .success ? UniColors.Status.successForeground : UniColors.Status.errorForeground)
                }

                Spacer()

                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Save to Photos", variant: .secondary, systemImage: "square.and.arrow.down") {
                        saveToPhotos()
                    }
                    UniButton(title: "Close", variant: .primary) { dismiss() }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.m)
            }
            .padding(.top, UniSpacing.l)
            .frame(maxWidth: .infinity)
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text(verbatim: navTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
        .task {
            qr = await QRCodeGenerator.shared.image(for: payload, scale: 12, displayScale: displayScale)
        }
    }

    /// White rounded plate + the caller's centred mark, sized at 20% of the
    /// QR — comfortably inside the "H" recovery budget.
    private var centreMark: some View {
        let plate: CGFloat = 48
        return ZStack {
            RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous)
                .fill(Color.white)
                .frame(width: plate, height: plate)
            center()
                .frame(width: plate - 14, height: plate - 14)
                .clipShape(RoundedRectangle(cornerRadius: UniRadius.xs, style: .continuous))
        }
    }

    private func saveToPhotos() {
        guard let qr else { return }
        #if canImport(UIKit)
        let saver = PhotoSaver { ok in saveResult = ok ? .success : .failure }
        saver.save(qr)
        #endif
    }
}

#if canImport(UIKit)
/// Tiny `UIImageWriteToSavedPhotosAlbum` completion bridge — retained by
/// the closure until the system callback fires.
private final class PhotoSaver: NSObject {
    private let completion: (Bool) -> Void
    private var strongSelf: PhotoSaver?
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    func save(_ image: UIImage) {
        strongSelf = self
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(done(_:error:contextInfo:)), nil)
    }
    @objc private func done(_ image: UIImage, error: Error?, contextInfo: UnsafeRawPointer?) {
        completion(error == nil)
        strongSelf = nil
    }
}
#endif

// MARK: - Shared: tap-to-reveal gate

/// Blurs its content until an explicit tap; re-blurs when the app
/// backgrounds (handoff security requirement). Reduced-motion shows the
/// final state without an animated lift.
private struct ExportRevealGate<Content: View>: View {
    @Binding var revealed: Bool
    @ViewBuilder var content: Content

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content
                .blur(radius: revealed ? 0 : 18)
                .allowsHitTesting(revealed)

            if !revealed {
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: UniSpacing.s) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 26, weight: .regular))
                                .foregroundStyle(UniColors.Icon.secondary)
                                .frame(width: 56, height: 56)
                                .background(Circle().fill(UniColors.Background.secondary))
                            Text("Tap to reveal")
                                .font(UniTypography.bodyEmphasized)
                                .foregroundStyle(UniColors.Text.primary)
                            Text("Make sure no one is watching")
                                .font(UniTypography.footnote)
                                .foregroundStyle(UniColors.Text.secondary)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
                    .onTapGesture { reveal() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("Tap to reveal"))
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { revealed = false }
        }
    }

    private func reveal() {
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        if reduceMotion {
            revealed = true
        } else {
            withAnimation(.easeOut(duration: 0.25)) { revealed = true }
        }
    }
}

// MARK: - Shared: bottom action bar (Copy + Done)

private struct ExportActionBar: View {
    let copyTitle: LocalizedStringKey
    /// The trailing primary button's label — "Backup Now" on the recovery
    /// flow, "Done" on the key flow (2026-06-19 user direction).
    let doneTitle: LocalizedStringKey
    @Binding var copied: Bool
    /// Whether the secret is currently revealed. Copy is disabled until the
    /// user lifts the blur (2026-06-19 user direction) — tapping it while
    /// hidden flashes the button red and asks them to reveal first.
    let isRevealed: Bool
    let onCopy: () -> Void
    let onDone: () -> Void

    @State private var secondsLeft: Int = 0
    /// Set when the user taps Copy before revealing — turns the button red
    /// and shows the "tap to reveal first" hint, then auto-clears.
    @State private var needsReveal = false

    var body: some View {
        // No pinned bar, no hairline, no separate surface (2026-06-19 user
        // direction) — the actions sit flush on the screen. Copy takes the
        // flexible width; Done is a fixed, narrower trailing button so Copy
        // always reads as the wider of the two.
        VStack(spacing: UniSpacing.xs) {
            if needsReveal {
                Text("Tap to reveal first")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Status.errorForeground)
            } else if secondsLeft > 0 {
                Text(verbatim: clipboardCaption)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            HStack(spacing: UniSpacing.s) {
                // Copy is disabled until the secret is revealed. We keep the
                // button tappable while hidden so the tap can flash it red
                // and prompt "tap to reveal first" — a silently-dead button
                // would just read as broken.
                UniButton(
                    title: copied ? "Copied" : copyTitle,
                    variant: needsReveal ? .destructive : .secondary,
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                ) {
                    if isRevealed {
                        onCopy()
                        startCountdown()
                    } else {
                        promptReveal()
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(isRevealed || needsReveal ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.2), value: needsReveal)
                .accessibilityHint(isRevealed ? Text("") : Text("Reveal the phrase before copying"))

                UniButton(title: doneTitle, variant: .primary) { onDone() }
                    .frame(width: 132)
            }
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.m)
        .onChange(of: isRevealed) { _, revealed in
            if revealed { needsReveal = false }
        }
        .task(id: needsReveal) {
            guard needsReveal else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) { needsReveal = false }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard secondsLeft > 0 else { return }
            secondsLeft -= 1
            if secondsLeft == 0 { copied = false }
        }
    }

    /// User tapped Copy before revealing — warn + flash red.
    private func promptReveal() {
        UniHapticEngine.shared.play(.warning)
        withAnimation(.easeOut(duration: 0.2)) { needsReveal = true }
    }

    private var clipboardCaption: String {
        if secondsLeft <= 0 { return String.apertureLocalized("Clipboard cleared") }
        return String(format: String.apertureLocalized("Clipboard clears in %llds"), Int64(secondsLeft))
    }

    private func startCountdown() {
        UniHapticEngine.shared.play(.selection)
        withAnimation(.easeOut(duration: 0.2)) { copied = true }
        secondsLeft = ExportClipboard.clearSeconds
    }
}

// MARK: - Shared: warning screen

/// One Apple-consent-style row: icon + bold lead + gray detail (no card
/// chrome).
private struct ExportWarnRow: View {
    struct Model: Identifiable {
        let id = UUID()
        let icon: String
        let lead: LocalizedStringKey
        let detail: LocalizedStringKey
    }
    let model: Model

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.m) {
            Image(systemName: model.icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 30, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.lead)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(model.detail)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The shared consent screen for both flows: a soft-red caution hero, a
/// centered title + lede, the icon-rows, and a neutral glass "Reveal…"
/// CTA + ghost "Cancel" (red is the caution accent only, never the
/// button — brand rule).
private struct ExportWarnScreen: View {
    let title: LocalizedStringKey
    let lede: LocalizedStringKey
    let rows: [ExportWarnRow.Model]
    let revealTitle: LocalizedStringKey
    let onReveal: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    // Bare warning glyph — no circular plate behind it
                    // (2026-06-19 user direction). Sized up so it still reads
                    // as the hero now that the red disc is gone. Shared by the
                    // recovery-phrase AND private-key warning screens.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 52, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(UniColors.Status.errorForeground)
                        .padding(.top, UniSpacing.l)
                        .accessibilityHidden(true)

                    VStack(spacing: UniSpacing.xs) {
                        Text(title)
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(lede)
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: UniSpacing.l) {
                        ForEach(rows) { ExportWarnRow(model: $0) }
                    }
                    .padding(.top, UniSpacing.s)
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: UniSpacing.xs) {
                UniButton(title: revealTitle, variant: .primary) {
                    UniHapticEngine.shared.play(.warning)
                    onReveal()
                }
                UniButton(title: "Cancel", variant: .secondary) { onCancel() }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.m)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
    }
}
