import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import WalletCore

/// Step 3 of the Receive sheet — the QR card + address + share +
/// chain-mismatch warning, composed for one specific (chain, optional
/// token) pair. Reused from both the native-row direct path (Step 1
/// → Step 3) and the token route (Step 1 → Step 2 → Step 3).
///
/// **Why factor this out of the v1 root.** The QR card, the address
/// row, and the chain-mismatch footer are the parts of the v1 Receive
/// screen that earned their place — they're per Rule #2 / #16 / #18.
/// The v2 redesign replaces the chain-chip picker at the top with
/// the asset list + network picker steps; this view is what the user
/// reaches at the end of either route.
///
/// **Layers (Rule #2 §B.3):** content layer — white QR card on opaque
/// surface + opaque address row + opaque warning footer. Functional
/// layer — system nav bar (parent NavigationStack), unified action
/// buttons.
struct ReceiveQRDetailView: View {
    let chain: SupportedChain
    /// `nil` when the user landed here from a native-asset tap;
    /// non-nil when they landed via the network picker for a token.
    let tokenSymbol: String?
    let address: String

    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @Query(sort: \WalletRecord.sortOrder) private var wallets: [WalletRecord]

    @State private var justCopiedAt: Date?
    @State private var isCopyButtonCopied: Bool = false
    @State private var copyButtonResetTask: Task<Void, Never>?
    @State private var isShowingGuide: Bool = false
    @State private var isShowingShareOptions: Bool = false
    @State private var sharePayload: ReceiveSharePayload?
    @State private var bitcoinChoices: [BitcoinReceiveAddressChoice] = []
    @State private var selectedBitcoinTypeRaw: String = ""
    @State private var evmOverrideAddress: String?
    @State private var isShowingEVMAccountSearch: Bool = false
    @State private var solanaOverrideAddress: String?
    @State private var isShowingSolanaAccountSearch: Bool = false
    @State private var receivedNotice: ReceiveIncomingNotice?
    @State private var lastReceiveNoticeHash: String?

    /// What the user is receiving, in the toolbar title. Native →
    /// chain name; token → "USDC".
    private var navigationTitleText: String {
        if let tokenSymbol {
            return tokenSymbol
        }
        return chain.displayName
    }

    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(
            rawID: activeWalletIdRaw,
            wallets: wallets,
            modelContext: modelContext
        )
    }

    private var displayedAddress: String {
        if chain == .bitcoin {
            return selectedBitcoinChoice?.address ?? bitcoinChoices.first?.address ?? address
        }
        if chain.family == .evm {
            return evmOverrideAddress ?? preferredEVMReceiveAddress ?? address
        }
        if chain == .solana {
            return solanaOverrideAddress ?? preferredReceiveAddress(for: .solana) ?? address
        }
        return address
    }

    private var preferredEVMReceiveAddress: String? {
        guard chain.family == .evm else { return nil }
        return preferredReceiveAddress(for: chain)
    }

    private func preferredReceiveAddress(for targetChain: SupportedChain) -> String? {
        let rows = activeWallet?.addresses.filter {
            $0.chainRaw == targetChain.rawValue && !$0.address.isEmpty
        } ?? []
        return rows.first(where: \.isReceivePreferred)?.address ?? rows.first?.address
    }

    private var selectedBitcoinChoice: BitcoinReceiveAddressChoice? {
        guard chain == .bitcoin else { return nil }
        if let selected = bitcoinChoices.first(where: { $0.type.rawValue == selectedBitcoinTypeRaw }) {
            return selected
        }
        return bitcoinChoices.first
    }

    private var showsBitcoinTypePicker: Bool {
        chain == .bitcoin && bitcoinChoices.count > 1
    }

    private var receiveMonitorTaskID: String {
        [
            activeWalletIdRaw,
            chain.rawValue,
            tokenSymbol ?? chain.ticker,
            displayedAddress,
            currencyCode.uppercased()
        ].joined(separator: "|")
    }

    private var bitcoinSelectionStorageKey: String? {
        guard chain == .bitcoin, let walletID = activeWallet?.id.uuidString else { return nil }
        return "receive.bitcoin.addressType.\(walletID)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UniSpacing.l) {
                ReceiveQRCard(
                    chain: chain,
                    tokenSymbol: tokenSymbol,
                    address: displayedAddress
                )
                ReceiveAddressRow(
                    address: displayedAddress,
                    justCopiedAt: $justCopiedAt
                )
                if let receivedNotice {
                    ReceiveIncomingNoticeCard(notice: receivedNotice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                actionRow
                ReceiveChainMismatchFooter(
                    chain: chain,
                    tokenSymbol: tokenSymbol,
                    onInfoTapped: { isShowingGuide = true }
                )
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: tokenSymbol, verb: "Receive")
            }
        }
        .sheet(isPresented: $isShowingGuide) {
            ReceiveGuideSheet(
                chain: chain,
                tokenSymbol: tokenSymbol,
                onDismiss: { isShowingGuide = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(item: $sharePayload) { payload in
            ReceiveActivityShareSheet(items: payload.items)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingEVMAccountSearch) {
            ReceiveEVMAccountSearchSheet(
                chain: chain,
                tokenSymbol: tokenSymbol,
                activeAddress: displayedAddress,
                wallet: activeWallet
            ) { newAddress in
                evmOverrideAddress = newAddress
            }
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingSolanaAccountSearch) {
            ReceiveSolanaAccountSearchSheet(
                activeAddress: displayedAddress,
                wallet: activeWallet
            ) { newAddress in
                solanaOverrideAddress = newAddress
            }
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        .task(id: "\(activeWalletIdRaw)-\(chain.rawValue)-\(address)") {
            evmOverrideAddress = nil
            solanaOverrideAddress = nil
            loadBitcoinAddressChoices()
        }
        .task(id: receiveMonitorTaskID) {
            await runReceiveMonitor()
        }
        .onChange(of: selectedBitcoinTypeRaw) { _, newValue in
            guard let key = bitcoinSelectionStorageKey,
                  BitcoinReceiveAddressType(rawValue: newValue) != nil else { return }
            UserDefaults.standard.set(newValue, forKey: key)
        }
        .onChange(of: justCopiedAt) { _, newValue in
            guard newValue != nil else { return }
            showCopyButtonFeedback()
        }
        .onChange(of: displayedAddress) { _, _ in
            resetCopyButtonFeedback()
        }
        .onDisappear {
            copyButtonResetTask?.cancel()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: UniSpacing.s) {
            UniButton(
                verbatim: isCopyButtonCopied ? "Copied" : "Copy",
                variant: .primary,
                tint: isCopyButtonCopied ? UniColors.Feedback.Success.foreground : nil
            ) {
                copyDisplayedAddress()
            }

            UniButton(title: "Share", variant: .secondary) {
                isShowingShareOptions = true
            }
            .popover(
                isPresented: $isShowingShareOptions,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                ReceiveShareOptionsPopover(
                    onShareQR: {
                        isShowingShareOptions = false
                        shareQRCode()
                    },
                    onShareAddress: {
                        isShowingShareOptions = false
                        sharePayload = ReceiveSharePayload(items: [displayedAddress])
                    }
                )
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func shareQRCode() {
        let payloadAddress = displayedAddress
        let symbol = tokenSymbol ?? chain.ticker
        Task {
            let image = await QRCodeGenerator.shared.brandedImage(
                for: payloadAddress,
                chain: chain,
                tokenSymbol: symbol,
                displayScale: displayScale
            )
            if let image {
                sharePayload = ReceiveSharePayload(items: [image])
            } else {
                sharePayload = ReceiveSharePayload(items: [payloadAddress])
            }
        }
    }

    private func copyDisplayedAddress() {
        SafePasteboard.setItems(
            [[UTType.plainText.identifier: displayedAddress]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            justCopiedAt = Date()
        }
    }

    private func showCopyButtonFeedback() {
        copyButtonResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            isCopyButtonCopied = true
        }
        copyButtonResetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCopyButtonCopied = false
                }
            }
        }
    }

    private func resetCopyButtonFeedback() {
        copyButtonResetTask?.cancel()
        isCopyButtonCopied = false
    }

    @MainActor
    private func runReceiveMonitor() async {
        receivedNotice = nil
        lastReceiveNoticeHash = nil

        guard let walletID = activeWallet?.id else { return }
        let monitoredAddress = displayedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !monitoredAddress.isEmpty else { return }

        let startedAt = Date()
        let monitoredTokenSymbol = tokenSymbol
        let monitoredCurrency = currencyCode.uppercased()
        let container = modelContext.container

        while !Task.isCancelled {
            await WalletDataRefreshCoordinator.shared.refreshChain(
                walletId: walletID,
                chain: chain,
                currencyCode: monitoredCurrency,
                modelContainer: container
            )
            if Task.isCancelled { return }

            await loadReceiveNotice(
                walletID: walletID,
                address: monitoredAddress,
                tokenSymbol: monitoredTokenSymbol,
                currencyCode: monitoredCurrency,
                since: startedAt,
                modelContainer: container
            )
            if Task.isCancelled { return }

            try? await Task.sleep(for: .seconds(8))
        }
    }

    @MainActor
    private func loadReceiveNotice(
        walletID: UUID,
        address: String,
        tokenSymbol: String?,
        currencyCode: String,
        since startedAt: Date,
        modelContainer: ModelContainer
    ) async {
        let repository = TransactionRepository(modelContainer: modelContainer)
        guard let snapshot = try? await repository.latestIncomingReceiveTransaction(
            walletId: walletID,
            chain: chain,
            address: address,
            tokenSymbol: tokenSymbol,
            currencyCode: currencyCode,
            since: startedAt
        ) else {
            return
        }

        let notice = ReceiveIncomingNotice(
            snapshot: snapshot,
            chainName: chain.displayName
        )
        guard notice.id != receivedNotice?.id || notice.status != receivedNotice?.status else {
            return
        }

        lastReceiveNoticeHash = snapshot.txHash
        withAnimation(.easeInOut(duration: 0.2)) {
            receivedNotice = notice
        }
    }

    private func loadBitcoinAddressChoices() {
        guard chain == .bitcoin else {
            bitcoinChoices = []
            selectedBitcoinTypeRaw = ""
            return
        }

        let resolution = BitcoinReceiveAddressResolver.resolve(
            wallet: activeWallet,
            fallbackAddress: address,
            modelContext: modelContext
        )
        bitcoinChoices = resolution.choices

        let savedRaw = bitcoinSelectionStorageKey.flatMap { UserDefaults.standard.string(forKey: $0) }
        let savedType = savedRaw.flatMap(BitcoinReceiveAddressType.init(rawValue:))
        let preferredType = savedType.flatMap { saved in
            resolution.choices.contains(where: { $0.type == saved }) ? saved : nil
        } ?? resolution.defaultType
        selectedBitcoinTypeRaw = preferredType.rawValue
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if chain == .bitcoin {
                Menu {
                    if showsBitcoinTypePicker {
                        Menu("Change type") {
                            ForEach(bitcoinChoices) { choice in
                                Button {
                                    selectedBitcoinTypeRaw = choice.type.rawValue
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(choice.type.title)
                                            Text(choice.type.subtitle)
                                        }
                                    } icon: {
                                        if selectedBitcoinTypeRaw == choice.type.rawValue {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } else if let choice = selectedBitcoinChoice {
                        Button {
                        } label: {
                            Text("\(choice.type.title) - \(choice.type.subtitle)")
                        }
                        .disabled(true)
                    }

                    Button("Address info") {
                        isShowingGuide = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("Bitcoin receive options"))
            } else if chain.family == .evm {
                Menu {
                    Button("Search accounts") {
                        isShowingEVMAccountSearch = true
                    }

                    Button("Address info") {
                        isShowingGuide = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("Receive options"))
            } else if chain == .solana {
                Menu {
                    Button("Search accounts") {
                        isShowingSolanaAccountSearch = true
                    }

                    Button("Address info") {
                        isShowingGuide = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("Solana receive options"))
            } else {
                Button {
                    isShowingGuide = true
                } label: {
                    // Bare `info.circle` per M-002/M-003 — toolbar icons
                    // inherit nav-bar tinting; no extra chrome wrapper.
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("What's a receive address?"))
            }
        }
    }
}

private struct ReceiveShareOptionsPopover: View {
    let onShareQR: () -> Void
    let onShareAddress: () -> Void

    var body: some View {
        VStack(spacing: UniSpacing.s) {
            Text("Share")
                .font(UniTypography.title3)
                .foregroundStyle(UniColors.Text.primary)
                .frame(maxWidth: .infinity)

            UniButton(title: "Share QR code", variant: .secondary, action: onShareQR)
            UniButton(title: "Share address", variant: .secondary, action: onShareAddress)
        }
        .padding(UniSpacing.m)
        .frame(width: 270)
        .background(UniColors.Background.primary)
    }
}

private struct ReceiveIncomingNotice: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let status: TransactionStatus

    init(
        snapshot: TransactionRepository.ReceiveIncomingTransactionSnapshot,
        chainName: String
    ) {
        let amount = Decimal(string: snapshot.amountRaw) ?? .zero
        let nativeText = "+\(WalletFormatting.native(amount, decimals: WalletFormatting.maxDisplayFractionDigits)) \(snapshot.tokenSymbol)"
        let fiatText = snapshot.fiatValue.map {
            WalletFormatting.fiat($0, currencyCode: snapshot.fiatCurrencyCode)
        }
        self.id = snapshot.txHash
        self.title = "Received \(fiatText ?? nativeText)"
        self.subtitle = "\(nativeText) in \(chainName) • \(Self.relativeTime(snapshot.occurredAt))"
        self.status = snapshot.status
    }

    var statusText: String {
        switch status {
        case .confirmed: return "Confirmed"
        case .pending: return "Pending"
        case .failed: return "Failed"
        }
    }

    var statusColor: Color {
        switch status {
        case .confirmed: return UniColors.Feedback.Success.foreground
        case .pending: return UniColors.Feedback.Warning.foreground
        case .failed: return UniColors.Feedback.Error.foreground
        }
    }

    var statusBackground: Color {
        switch status {
        case .confirmed: return UniColors.Feedback.Success.background
        case .pending: return UniColors.Feedback.Warning.background
        case .failed: return UniColors.Feedback.Error.background
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed >= 0 && elapsed < 10 {
            return String.apertureLocalized("A few seconds ago")
        }
        return WalletFormatting.activityRelativeTime(date)
    }
}

private struct ReceiveIncomingNoticeCard: View {
    let notice: ReceiveIncomingNotice

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(UniColors.Feedback.Success.foreground)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: notice.title)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: notice.subtitle)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: UniSpacing.xs)

            Text(verbatim: notice.statusText)
                .font(UniTypography.caption1)
                .foregroundStyle(notice.statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(notice.statusBackground)
                )
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Card.background)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct ReceiveSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct ReceiveActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum BitcoinReceiveAddressType: String, CaseIterable, Identifiable {
    case bip86
    case bip84
    case bip49
    case bip44

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bip86: return "BIP86"
        case .bip84: return "BIP84"
        case .bip49: return "BIP49"
        case .bip44: return "BIP44"
        }
    }

    var subtitle: String {
        switch self {
        case .bip86:
            return "Taproot, starts with bc1p."
        case .bip84:
            return "Native SegWit, starts with bc1q."
        case .bip49:
            return "Wrapped SegWit, starts with 3."
        case .bip44:
            return "Legacy, starts with 1."
        }
    }
}

private struct BitcoinReceiveAddressChoice: Identifiable, Equatable {
    let type: BitcoinReceiveAddressType
    let address: String

    var id: String { type.rawValue }
}

private struct BitcoinReceiveAddressResolution {
    let choices: [BitcoinReceiveAddressChoice]
    let defaultType: BitcoinReceiveAddressType
}

private enum BitcoinReceiveAddressResolver {
    static func resolve(
        wallet: WalletRecord?,
        fallbackAddress: String,
        modelContext: ModelContext
    ) -> BitcoinReceiveAddressResolution {
        if let wallet,
           wallet.hasPassphrase == false,
           let words = try? WalletSecretPersistence.loadMnemonic(for: wallet.id, in: modelContext),
           !words.isEmpty,
           let result = resolveMnemonic(words) {
            return result
        }

        if let wallet,
           let privateKey = try? WalletSecretPersistence.loadPrivateKey(for: wallet.id, in: modelContext),
           let result = resolvePrivateKey(privateKey) {
            return result
        }

        let inferred = inferType(address: fallbackAddress)
        return BitcoinReceiveAddressResolution(
            choices: [BitcoinReceiveAddressChoice(type: inferred, address: fallbackAddress)],
            defaultType: inferred
        )
    }

    private static func resolveMnemonic(_ words: [String]) -> BitcoinReceiveAddressResolution? {
        let phrase = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let wallet = HDWallet(mnemonic: phrase, passphrase: "") else { return nil }

        var choices: [BitcoinReceiveAddressChoice] = []
        if let address = wallet.getAddressDerivation(coin: .bitcoin, derivation: .bitcoinTaproot).nonEmpty {
            choices.append(BitcoinReceiveAddressChoice(type: .bip86, address: address))
        }
        if let address = wallet.getAddressDerivation(coin: .bitcoin, derivation: .bitcoinSegwit).nonEmpty {
            choices.append(BitcoinReceiveAddressChoice(type: .bip84, address: address))
        }
        if let address = mnemonicBIP49Address(wallet: wallet) {
            choices.append(BitcoinReceiveAddressChoice(type: .bip49, address: address))
        }
        if let address = wallet.getAddressDerivation(coin: .bitcoin, derivation: .bitcoinLegacy).nonEmpty {
            choices.append(BitcoinReceiveAddressChoice(type: .bip44, address: address))
        }
        guard !choices.isEmpty else { return nil }
        return BitcoinReceiveAddressResolution(choices: choices, defaultType: .bip84)
    }

    private static func resolvePrivateKey(_ raw: String) -> BitcoinReceiveAddressResolution? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extended = extendedPrivateKeyAddress(trimmed) {
            return extended
        }
        guard let decoded = decodeBitcoinPrivateKey(trimmed) else { return nil }
        let keyData = decoded.keyData
        guard let privateKey = PrivateKey(data: keyData) else { return nil }

        if decoded.isUncompressedWIF {
            guard let address = p2pkhAddress(privateKey: privateKey, compressed: false) else { return nil }
            return BitcoinReceiveAddressResolution(
                choices: [BitcoinReceiveAddressChoice(type: .bip44, address: address)],
                defaultType: .bip44
            )
        }

        var choices: [BitcoinReceiveAddressChoice] = []
        if let address = bip84Address(privateKey: privateKey) {
            choices.append(BitcoinReceiveAddressChoice(type: .bip84, address: address))
        }
        if let address = bip49Address(privateKey: privateKey) {
            choices.append(BitcoinReceiveAddressChoice(type: .bip49, address: address))
        }
        if let address = p2pkhAddress(privateKey: privateKey, compressed: true) {
            choices.append(BitcoinReceiveAddressChoice(type: .bip44, address: address))
        }
        guard !choices.isEmpty else { return nil }
        return BitcoinReceiveAddressResolution(choices: choices, defaultType: .bip84)
    }

    private static func mnemonicBIP49Address(wallet: HDWallet) -> String? {
        let privateKey = wallet.getKey(coin: .bitcoin, derivationPath: "m/49'/0'/0'/0/0")
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true)
        return BitcoinAddress.compatibleAddress(
            publicKey: publicKey,
            prefix: CoinType.bitcoin.p2shPrefix
        ).description.nonEmpty
    }

    private static func extendedPrivateKeyAddress(_ raw: String) -> BitcoinReceiveAddressResolution? {
        guard let payload = WalletCore.Base58.decode(string: raw),
              payload.count == 78 else {
            return nil
        }
        let version = payload.apertureReceiveBitcoinUInt32BE(at: 0)
        let publicVersion: UInt32
        let type: BitcoinReceiveAddressType
        switch version {
        case 0x0488_ADE4:
            publicVersion = 0x0488_B21E
            type = .bip44
        case 0x049D_7878, 0x04B2_430C:
            // User direction: yprv and zprv default to BIP49 on Receive.
            publicVersion = 0x049D_7CB2
            type = .bip49
        default:
            return nil
        }

        let privateKeyPayload = payload.subdata(in: 45..<78)
        guard privateKeyPayload.count == 33,
              privateKeyPayload.first == 0,
              let privateKey = PrivateKey(data: Data(privateKeyPayload.dropFirst())) else {
            return nil
        }
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true).data
        guard publicKey.count == 33 else { return nil }

        var publicPayload = Data()
        publicPayload.append(publicVersion.apertureReceiveBitcoinBigEndianData)
        publicPayload.append(payload.subdata(in: 4..<45))
        publicPayload.append(publicKey)

        let publicExtendedKey = WalletCore.Base58.encode(data: publicPayload)
        let purpose: Purpose = type == .bip44 ? .bip44 : .bip49
        let path = DerivationPath(
            purpose: purpose,
            coin: CoinType.bitcoin.slip44Id,
            account: 0,
            change: 0,
            address: 0
        ).description
        guard let childPublicKey = HDWallet.getPublicKeyFromExtended(
            extended: publicExtendedKey,
            coin: .bitcoin,
            derivationPath: path
        ) else {
            return nil
        }

        let address: String?
        switch type {
        case .bip44:
            address = BitcoinAddress(
                publicKey: childPublicKey,
                prefix: CoinType.bitcoin.p2pkhPrefix
            )?.description
        case .bip49:
            address = BitcoinAddress.compatibleAddress(
                publicKey: childPublicKey,
                prefix: CoinType.bitcoin.p2shPrefix
            ).description
        case .bip84, .bip86:
            address = nil
        }
        guard let address = address?.nonEmpty else { return nil }
        return BitcoinReceiveAddressResolution(
            choices: [BitcoinReceiveAddressChoice(type: type, address: address)],
            defaultType: type
        )
    }

    private static func decodeBitcoinPrivateKey(_ raw: String) -> (keyData: Data, isUncompressedWIF: Bool)? {
        let hex = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
        if hex.count == 64,
           hex.allSatisfy(\.isHexDigit),
           let data = Data(apertureReceiveBitcoinHex: hex),
           PrivateKey.isValid(data: data, curve: CoinType.bitcoin.curve) {
            return (data, false)
        }

        guard let payload = WalletCore.Base58.decode(string: raw) else { return nil }
        let isUncompressed = payload.count == 33
        let isCompressed = payload.count == 34 && payload.last == 0x01
        guard payload.first == 0x80, isUncompressed || isCompressed else { return nil }
        let keyData = Data(payload.dropFirst().prefix(32))
        guard PrivateKey.isValid(data: keyData, curve: CoinType.bitcoin.curve) else { return nil }
        return (keyData, isUncompressed)
    }

    private static func bip84Address(privateKey: PrivateKey) -> String? {
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true)
        return CoinType.bitcoin.deriveAddressFromPublicKey(publicKey: publicKey).nonEmpty
    }

    private static func bip49Address(privateKey: PrivateKey) -> String? {
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true)
        return BitcoinAddress.compatibleAddress(
            publicKey: publicKey,
            prefix: CoinType.bitcoin.p2shPrefix
        ).description.nonEmpty
    }

    private static func p2pkhAddress(privateKey: PrivateKey, compressed: Bool) -> String? {
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: compressed)
        return BitcoinAddress(publicKey: publicKey, prefix: CoinType.bitcoin.p2pkhPrefix)?.description.nonEmpty
    }

    private static func inferType(address: String) -> BitcoinReceiveAddressType {
        let lower = address.lowercased()
        if lower.hasPrefix("bc1p") { return .bip86 }
        if lower.hasPrefix("bc1q") { return .bip84 }
        if lower.hasPrefix("3") { return .bip49 }
        return .bip44
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Data {
    init?(apertureReceiveBitcoinHex hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    func apertureReceiveBitcoinUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}

private extension UInt32 {
    var apertureReceiveBitcoinBigEndianData: Data {
        Data([
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ])
    }
}
