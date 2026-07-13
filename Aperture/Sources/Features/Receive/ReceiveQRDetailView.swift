import SwiftUI
import UIKit
import UniformTypeIdentifiers
import GRDB
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
    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    @State private var justCopiedAt: Date?
    @State private var isCopyButtonCopied: Bool = false
    @State private var copyButtonResetTask: Task<Void, Never>?
    @State private var isShowingGuide: Bool = false
    @State private var isShowingShareOptions: Bool = false
    @State private var sharePayload: ReceiveSharePayload?
    @State private var bitcoinChoices: [BitcoinReceiveAddressChoice] = []
    @State private var selectedBitcoinTypeRaw: String = ""
    @State private var bitcoinOverrideAddress: String?
    @State private var isShowingBitcoinPathSearch: Bool = false
    @State private var evmOverrideAddress: String?
    @State private var isShowingEVMAccountSearch: Bool = false
    @State private var solanaOverrideAddress: String?
    @State private var isShowingSolanaAccountSearch: Bool = false
    @State private var isSwitchingSolanaPath: Bool = false
    @State private var solanaPathSwitchError: String?
    /// Pending path style when a passphrase wallet must enter the BIP-39 phrase first.
    @State private var pendingSolanaPathStyle: SolanaPathStyle?
    @State private var isShowingSolanaPassphrase: Bool = false
    /// Native SOL (and optional fiat) per path style for the Address path menu.
    @State private var solanaPathBalanceLabels: [SolanaPathStyle: String] = [:]
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    /// What the user is receiving, in the toolbar title. Native →
    /// chain name; token → "USDC".
    private var navigationTitleText: String {
        if let tokenSymbol {
            return tokenSymbol
        }
        return chain.displayName
    }

    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(rawID: activeWalletIdRaw, wallets: walletRecordsObservation.wallets)
    }

    private var displayedAddress: String {
        if chain == .bitcoin {
            // Path-search override wins when set. Otherwise the type picker
            // (`selectedBitcoinChoice`) must win over the DB preferred row —
            // previously preferred always won, so Change type only moved the
            // checkmark while QR/address stayed on BIP84 (or whatever was
            // preferred at provision time).
            if let override = bitcoinOverrideAddress, !override.isEmpty {
                return override
            }
            if let selected = selectedBitcoinChoice?.address, !selected.isEmpty {
                return selected
            }
            return preferredReceiveAddress(for: .bitcoin)
                ?? bitcoinChoices.first?.address
                ?? address
        }
        if chain.family == .evm {
            return evmOverrideAddress ?? preferredEVMReceiveAddress ?? address
        }
        if chain == .solana {
            return solanaOverrideAddress ?? preferredReceiveAddress(for: .solana) ?? address
        }
        return address
    }

    private var receivePayloadAddress: String {
        visibleAddress(for: displayedAddress)
    }

    private func visibleAddress(for rawAddress: String) -> String {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chain == .bitcoinCash else { return trimmed }
        let prefix = "bitcoincash:"
        guard trimmed.lowercased().hasPrefix(prefix) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
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

    /// Multi-type picker only when HD / compressed keys can produce more
    /// than one address form. Uncompressed WIF (`5…`) is legacy-only.
    private var showsBitcoinTypePicker: Bool {
        chain == .bitcoin && bitcoinChoices.count > 1
    }

    /// Path search needs an HD mnemonic (or equivalent). Single-key imports
    /// (including uncompressed WIF) have no alternate derivation paths.
    private var showsBitcoinPathSearch: Bool {
        guard chain == .bitcoin, let wallet = activeWallet else { return false }
        switch wallet.kind {
        case .created, .importedMnemonic:
            return true
        case .importedKey, .watchOnly:
            return false
        }
    }

    private var activeSolanaAddressRecord: WalletAddressRecord? {
        guard chain == .solana else { return nil }
        let rows = activeWallet?.addresses.filter {
            $0.chainRaw == SupportedChain.solana.rawValue && !$0.address.isEmpty
        } ?? []
        return rows.first(where: { $0.address == displayedAddress })
            ?? rows.first(where: \.isReceivePreferred)
            ?? rows.first
    }

    private var selectedSolanaPathStyle: SolanaPathStyle? {
        activeSolanaAddressRecord
            .flatMap { SolanaPathStyle.parse($0.derivationPath)?.style }
    }

    private var selectedSolanaPathAccount: Int {
        activeSolanaAddressRecord
            .flatMap { SolanaPathStyle.parse($0.derivationPath)?.account }
            ?? 0
    }

    private var canSwitchSolanaPath: Bool {
        guard chain == .solana, let wallet = activeWallet else { return false }
        // Passphrase wallets can switch after entering the passphrase
        // (session-cached; never empty-passphrase derive).
        return wallet.kind == .created || wallet.kind == .importedMnemonic
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
                    address: receivePayloadAddress,
                    onQRCodeTapped: {
                        shareQRCode()
                    }
                )
                ReceiveAddressRow(
                    address: receivePayloadAddress
                )
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
                CoinTitleBar(chain: chain, tokenSymbol: tokenSymbol, verb: "Receive", showsIcon: false)
            }
        }
        .sheet(isPresented: $isShowingGuide) {
            ReceiveGuideSheet(
                chain: chain,
                tokenSymbol: tokenSymbol,
                onDismiss: { isShowingGuide = false }
            )
            .apertureEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(item: $sharePayload) { payload in
            ReceiveActivityShareSheet(items: payload.items)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingBitcoinPathSearch) {
            ReceiveBitcoinPathSearchSheet(
                activeAddress: displayedAddress,
                wallet: activeWallet
            ) { newAddress in
                bitcoinOverrideAddress = newAddress
            }
            .apertureEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
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
            .apertureEnvironment()
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
            .apertureEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingSolanaPassphrase) {
            ReceiveSolanaPassphraseSheet(
                onSubmit: { entered in
                    isShowingSolanaPassphrase = false
                    guard let style = pendingSolanaPathStyle else { return }
                    pendingSolanaPathStyle = nil
                    performSolanaPathSwitch(to: style, passphrase: entered)
                },
                onCancel: {
                    isShowingSolanaPassphrase = false
                    pendingSolanaPathStyle = nil
                }
            )
            .apertureEnvironment()
            .uniSheetDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .task(id: "\(activeWalletIdRaw)-\(chain.rawValue)-\(address)") {
            bitcoinOverrideAddress = nil
            evmOverrideAddress = nil
            solanaOverrideAddress = nil
            loadBitcoinAddressChoices()
            await reconcileSolanaReceivePathIfNeeded()
            reloadSolanaPathBalances()
        }
        .onChange(of: selectedBitcoinTypeRaw) { _, newValue in
            guard let key = bitcoinSelectionStorageKey,
                  BitcoinReceiveAddressType(rawValue: newValue) != nil else { return }
            AppPreferenceStore.shared.set(newValue, forKey: key)
            // Drop any path-search override so the new type's address shows.
            bitcoinOverrideAddress = nil
            persistBitcoinReceiveTypePreferenceIfPossible(raw: newValue)
        }
        .onChange(of: justCopiedAt) { _, newValue in
            guard newValue != nil else { return }
            showCopyButtonFeedback()
        }
        .onChange(of: displayedAddress) { _, _ in
            resetCopyButtonFeedback()
        }
        .alert(
            "Couldn't change Solana path",
            isPresented: Binding(
                get: { solanaPathSwitchError != nil },
                set: { if !$0 { solanaPathSwitchError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { solanaPathSwitchError = nil }
        } message: {
            Text(solanaPathSwitchError ?? "")
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
                // Catalog keys "Copy" / "Copied" — never `verbatim`, or the
                // labels stay English while Share (localized `title:`) flips.
                title: isCopyButtonCopied ? "Copied" : "Copy",
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
                        sharePayload = ReceiveSharePayload(items: [receivePayloadAddress])
                    }
                )
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func shareQRCode() {
        let payloadAddress = receivePayloadAddress
        let symbol = tokenSymbol ?? chain.ticker
        Task {
            let image = await QRCodeGenerator.shared.brandedImage(
                for: payloadAddress,
                chain: chain,
                tokenSymbol: symbol,
                displayScale: displayScale
            )
            if let image {
                sharePayload = ReceiveSharePayload(items: [writeQRCodePNG(image, symbol: symbol) ?? image])
            } else {
                sharePayload = ReceiveSharePayload(items: [payloadAddress])
            }
        }
    }

    private func writeQRCodePNG(_ image: UIImage, symbol: String) -> URL? {
        guard let data = image.pngData() else { return nil }
        let safeSymbol = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let fileName = "Aperture-\(chain.ticker)-\(safeSymbol.isEmpty ? "receive" : safeSymbol)-QR.png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private func copyDisplayedAddress() {
        SafePasteboard.setItems(
            [[UTType.plainText.identifier: receivePayloadAddress]],
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

    private func loadBitcoinAddressChoices() {
        guard chain == .bitcoin else {
            bitcoinChoices = []
            selectedBitcoinTypeRaw = ""
            return
        }

        let resolution = BitcoinReceiveAddressResolver.resolve(
            wallet: activeWallet,
            fallbackAddress: address,
            database: AppDatabase.shared
        )
        bitcoinChoices = resolution.choices

        let savedRaw = bitcoinSelectionStorageKey.map { AppPreferenceStore.shared.string($0, default: "") }
        let savedType = savedRaw.flatMap(BitcoinReceiveAddressType.init(rawValue:))
        // Prefer an explicit user choice when still valid; otherwise the
        // resolver default (BIP84 for mnemonic / compressed keys; BIP44 only
        // for uncompressed WIF).
        let preferredType = savedType.flatMap { saved in
            resolution.choices.contains(where: { $0.type == saved }) ? saved : nil
        } ?? resolution.defaultType
        selectedBitcoinTypeRaw = preferredType.rawValue

        // Stamp BIP84 as preferred when that is the active default and
        // nothing was saved yet — keeps DB preferred in line with the QR.
        if savedType == nil,
           preferredType == .bip84,
           resolution.choices.contains(where: { $0.type == .bip84 }) {
            if let key = bitcoinSelectionStorageKey {
                AppPreferenceStore.shared.set(BitcoinReceiveAddressType.bip84.rawValue, forKey: key)
            }
            persistBitcoinReceiveTypePreferenceIfPossible(raw: BitcoinReceiveAddressType.bip84.rawValue)
        }
    }

    /// Keep wallet_addresses + chain_states in sync with the type the user
    /// picked so home/history preferred receive matches the QR they see.
    private func persistBitcoinReceiveTypePreferenceIfPossible(raw: String) {
        guard chain == .bitcoin,
              let wallet = activeWallet,
              let type = BitcoinReceiveAddressType(rawValue: raw),
              let choice = bitcoinChoices.first(where: { $0.type == type }) else {
            return
        }
        let walletId = wallet.id
        let address = choice.address
        let derivationPath = type.accountZeroPath
        let chainRaw = SupportedChain.bitcoin.rawValue
        let decimals = SupportedChain.bitcoin.nativeDecimals
        Task {
            do {
                try AppDatabase.shared.write { db in
                    let existingIdRaw = try String.fetchOne(
                        db,
                        sql: """
                        SELECT id FROM wallet_addresses
                        WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                        LIMIT 1
                        """,
                        arguments: [walletId.uuidString, chainRaw, address]
                    )
                    let addressId = existingIdRaw.flatMap(UUID.init(uuidString:)) ?? UUID()

                    try db.execute(
                        sql: """
                        UPDATE wallet_addresses
                        SET is_receive_preferred = 0
                        WHERE wallet_id = ? AND chain_raw = ?
                        """,
                        arguments: [walletId.uuidString, chainRaw]
                    )

                    if existingIdRaw != nil {
                        try db.execute(
                            sql: """
                            UPDATE wallet_addresses
                            SET derivation_path = ?,
                                is_receive_preferred = 1
                            WHERE id = ?
                            """,
                            arguments: [derivationPath, addressId.uuidString]
                        )
                    } else {
                        try db.execute(
                            sql: """
                            INSERT INTO wallet_addresses
                            (id, wallet_id, chain_raw, address, derivation_path,
                             is_used, is_receive_preferred, last_scanned_at_ms)
                            VALUES (?, ?, ?, ?, ?, 0, 1, NULL)
                            """,
                            arguments: [
                                addressId.uuidString,
                                walletId.uuidString,
                                chainRaw,
                                address,
                                derivationPath
                            ]
                        )
                    }

                    try db.execute(
                        sql: """
                        INSERT INTO chain_states
                        (id, wallet_id, chain_raw, address, derivation_path,
                         native_balance_raw, native_decimals, native_fiat,
                         native_fiat_numeric, total_fiat, total_fiat_numeric,
                         token_count, fiat_currency_code, sync_state_raw)
                        VALUES (?, ?, ?, ?, ?, '0', ?, '0', 0, '0', 0, 0, ?, 'idle')
                        ON CONFLICT(wallet_id, chain_raw) DO UPDATE SET
                            address = excluded.address,
                            derivation_path = excluded.derivation_path
                        """,
                        arguments: [
                            UUID().uuidString,
                            walletId.uuidString,
                            chainRaw,
                            address,
                            derivationPath,
                            decimals,
                            CurrencyPreference.defaultCode
                        ]
                    )
                }
            } catch {
                // Preference key + on-screen address already updated; DB stamp
                // is best-effort so a write failure must not block the switch.
            }
        }
    }

    @MainActor
    private func switchSolanaPath(to style: SolanaPathStyle) {
        guard canSwitchSolanaPath, let wallet = activeWallet, isSwitchingSolanaPath == false else { return }
        solanaPathSwitchError = nil

        if wallet.hasPassphrase {
            // Prefer session passphrase; otherwise prompt (never empty-derive).
            Task {
                if let session = await BIP39PassphraseSession.shared.passphrase(for: wallet.id) {
                    performSolanaPathSwitch(to: style, passphrase: session)
                } else {
                    pendingSolanaPathStyle = style
                    isShowingSolanaPassphrase = true
                }
            }
            return
        }
        performSolanaPathSwitch(to: style, passphrase: "")
    }

    @MainActor
    private func performSolanaPathSwitch(to style: SolanaPathStyle, passphrase: String) {
        guard canSwitchSolanaPath, let wallet = activeWallet, isSwitchingSolanaPath == false else { return }
        isSwitchingSolanaPath = true
        solanaPathSwitchError = nil

        let walletId = wallet.id
        let walletKind = wallet.kind
        let hasPassphrase = wallet.hasPassphrase
        let account = selectedSolanaPathAccount
        let database = AppDatabase.shared

        Task {
            do {
                if hasPassphrase {
                    await BIP39PassphraseSession.shared.remember(walletId: walletId, passphrase: passphrase)
                    _ = await SolanaPathProvisioning.ensureBothAccountZeroPathsIfPossible(
                        walletId: walletId,
                        passphrase: passphrase,
                        database: database
                    )
                } else {
                    _ = await SolanaPathProvisioning.ensureBothAccountZeroPathsIfPossible(
                        walletId: walletId,
                        passphrase: "",
                        database: database
                    )
                }

                let result = try await Task.detached(priority: .userInitiated) {
                    try SolanaReceivePathResolver.resolve(
                        walletId: walletId,
                        walletKind: walletKind,
                        hasPassphrase: hasPassphrase,
                        passphrase: passphrase,
                        style: style,
                        account: account,
                        database: database
                    )
                }.value
                try persistSolanaReceiveAddress(walletId: walletId, result: result)
                // Rebuild so home balance/history flip to the newly preferred path.
                let code = AppPreferenceStore.shared.string(
                    CurrencyPreference.storageKey,
                    default: CurrencyPreference.defaultCode
                )
                _ = try? ChainStateRepository(database: database).rebuild(
                    walletId: walletId,
                    fiatCurrencyCode: code,
                    onlyChains: [.solana],
                    failedChains: [],
                    interim: false
                )
                solanaOverrideAddress = result.address
                reloadSolanaPathBalances()
            } catch {
                solanaPathSwitchError = SolanaReceivePathSwitchError.message(for: error)
            }
            isSwitchingSolanaPath = false
        }
    }

    /// Ensure both account-0 paths exist in GRDB, heal mislabeled preferred
    /// address (Trust address labeled Phantom), and keep QR on the preferred path.
    @MainActor
    private func reconcileSolanaReceivePathIfNeeded() async {
        guard chain == .solana, canSwitchSolanaPath, let wallet = activeWallet else { return }
        guard isSwitchingSolanaPath == false else { return }

        let walletId = wallet.id
        let walletKind = wallet.kind
        let hasPassphrase = wallet.hasPassphrase
        let database = AppDatabase.shared

        do {
            // Dual-path heal: empty passphrase only for non-passphrase wallets;
            // passphrase wallets use the session cache when available (P1 #7).
            _ = await SolanaPathProvisioning.ensureBothAccountZeroPathsIfPossible(
                walletId: walletId,
                database: database
            )

            let style = selectedSolanaPathStyle ?? .phantom
            let account = selectedSolanaPathAccount
            let current = displayedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionPass = hasPassphrase
                ? await BIP39PassphraseSession.shared.passphrase(for: walletId)
                : Optional.some("")
            // Without a known passphrase, skip re-derive (would use wrong seed).
            guard let passphrase = sessionPass else { return }
            let result = try await Task.detached(priority: .userInitiated) {
                try SolanaReceivePathResolver.resolve(
                    walletId: walletId,
                    walletKind: walletKind,
                    hasPassphrase: hasPassphrase,
                    passphrase: passphrase,
                    style: style,
                    account: account,
                    database: database
                )
            }.value
            guard result.address != current
                    || activeSolanaAddressRecord?.derivationPath != result.derivationPath
            else { return }
            try persistSolanaReceiveAddress(walletId: walletId, result: result)
            solanaOverrideAddress = result.address
        } catch {
            // Soft heal — don't surface an alert on open; user can still switch manually.
        }
    }

    private func solanaPathBalanceSubtitle(for style: SolanaPathStyle) -> String {
        solanaPathBalanceLabels[style] ?? String.apertureLocalized("Balance unavailable")
    }

    @MainActor
    private func reloadSolanaPathBalances() {
        guard chain == .solana, let wallet = activeWallet else {
            solanaPathBalanceLabels = [:]
            return
        }
        let rows = wallet.addresses.filter { $0.chainRaw == SupportedChain.solana.rawValue }
        var labels: [SolanaPathStyle: String] = [:]
        let code = currencyCode

        let balancesByAddressId: [UUID: (raw: String, decimals: Int, fiat: Decimal, fiatCode: String)] = {
            (try? AppDatabase.shared.read { db in
                let idList = rows.map(\.id.uuidString)
                guard !idList.isEmpty else { return [:] }
                let placeholders = Array(repeating: "?", count: idList.count).joined(separator: ",")
                let sql = """
                SELECT address_id, raw_balance, decimals, fiat_value_cached, fiat_currency_code
                FROM token_balances
                WHERE token_contract IS NULL
                  AND UPPER(token_symbol) = 'SOL'
                  AND address_id IN (\(placeholders))
                """
                let fetched = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(idList))
                var map: [UUID: (String, Int, Decimal, String)] = [:]
                for row in fetched {
                    guard let id = UUID(uuidString: row["address_id"]) else { continue }
                    let raw: String = row["raw_balance"]
                    let decimals: Int = row["decimals"]
                    let fiat = Decimal(string: row["fiat_value_cached"] as String) ?? 0
                    let fiatCode: String = row["fiat_currency_code"]
                    map[id] = (raw, decimals, fiat, fiatCode)
                }
                return map
            }) ?? [:]
        }()

        for style in SolanaPathStyle.allCases {
            let match = rows.first { SolanaPathStyle.parse($0.derivationPath)?.style == style }
            guard let match, let bal = balancesByAddressId[match.id] else {
                labels[style] = "0 SOL"
                continue
            }
            let amount = WalletFormatting.decimalAmount(rawBalance: bal.raw, decimals: bal.decimals)
            let native = WalletFormatting.native(amount, decimals: 9, hidden: false)
            if bal.fiat > 0 {
                let fiatText = WalletFormatting.fiat(bal.fiat, currencyCode: bal.fiatCode.isEmpty ? code : bal.fiatCode, hidden: false)
                labels[style] = "\(native) SOL · \(fiatText)"
            } else {
                labels[style] = "\(native) SOL"
            }
        }
        solanaPathBalanceLabels = labels
    }

    @MainActor
    private func persistSolanaReceiveAddress(
        walletId: UUID,
        result: SolanaReceivePathSwitchResult
    ) throws {
        let chainRaw = SupportedChain.solana.rawValue
        try AppDatabase.shared.write { db in
            let existingIdRaw = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                LIMIT 1
                """,
                arguments: [walletId.uuidString, chainRaw, result.address]
            )
            let addressId = existingIdRaw.flatMap(UUID.init(uuidString:)) ?? UUID()

            try db.execute(
                sql: """
                UPDATE wallet_addresses
                SET is_receive_preferred = 0
                WHERE wallet_id = ? AND chain_raw = ?
                """,
                arguments: [walletId.uuidString, chainRaw]
            )

            if existingIdRaw != nil {
                try db.execute(
                    sql: """
                    UPDATE wallet_addresses
                    SET derivation_path = ?,
                        is_receive_preferred = 1
                    WHERE id = ?
                    """,
                    arguments: [result.derivationPath, addressId.uuidString]
                )
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO wallet_addresses
                    (id, wallet_id, chain_raw, address, derivation_path,
                     is_used, is_receive_preferred, last_scanned_at_ms)
                    VALUES (?, ?, ?, ?, ?, 0, 1, NULL)
                    """,
                    arguments: [
                        addressId.uuidString,
                        walletId.uuidString,
                        chainRaw,
                        result.address,
                        result.derivationPath
                    ]
                )
            }

            try db.execute(
                sql: """
                INSERT INTO chain_states
                (id, wallet_id, chain_raw, address, derivation_path,
                 native_balance_raw, native_decimals, native_fiat,
                 native_fiat_numeric, total_fiat, total_fiat_numeric,
                 token_count, fiat_currency_code, sync_state_raw)
                VALUES (?, ?, ?, ?, ?, '0', ?, '0', 0, '0', 0, 0, ?, 'idle')
                ON CONFLICT(wallet_id, chain_raw) DO UPDATE SET
                    address = excluded.address,
                    derivation_path = excluded.derivation_path
                """,
                arguments: [
                    UUID().uuidString,
                    walletId.uuidString,
                    chainRaw,
                    result.address,
                    result.derivationPath,
                    SupportedChain.solana.nativeDecimals,
                    CurrencyPreference.defaultCode
                ]
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if chain == .bitcoin {
                Menu {
                    if showsBitcoinPathSearch {
                        Button("Search paths") {
                            isShowingBitcoinPathSearch = true
                        }
                    }

                    // Only when multiple types exist. Uncompressed WIF (`5…`)
                    // is legacy-only — do not show Change type at all.
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

                    Menu("Address path") {
                        ForEach(SolanaPathStyle.allCases) { style in
                            Button {
                                switchSolanaPath(to: style)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(style.title)
                                        Text(solanaPathBalanceSubtitle(for: style))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    if selectedSolanaPathStyle == style {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .disabled(!canSwitchSolanaPath || isSwitchingSolanaPath)
                        }
                    }
                    .disabled(!canSwitchSolanaPath || isSwitchingSolanaPath)

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

private struct SolanaReceivePathSwitchResult: Sendable {
    let style: SolanaPathStyle
    let account: Int
    let derivationPath: String
    let address: String
}

private enum SolanaReceivePathSwitchError: Error {
    case unsupportedWallet
    case passphraseWallet
    case missingMnemonic
    case invalidMnemonic

    static func message(for error: Error) -> String {
        switch error {
        case SolanaReceivePathSwitchError.unsupportedWallet:
            return "This wallet has one fixed Solana address, so there is no alternate derivation path to select."
        case SolanaReceivePathSwitchError.passphraseWallet:
            return "This wallet uses a BIP-39 passphrase. Entering the passphrase is required before alternate Solana paths can be derived."
        case SolanaReceivePathSwitchError.missingMnemonic:
            return "The recovery phrase is not available on this device."
        case SolanaReceivePathSwitchError.invalidMnemonic:
            return "The saved recovery phrase could not derive a Solana address."
        default:
            return error.localizedDescription
        }
    }
}

private enum SolanaReceivePathResolver {
    /// Derive a Solana receive address for the chosen path style.
    ///
    /// Uses the same SLIP-0010 ed25519 path as `ReceiveSolanaAccountSearchSheet`
    /// (`Ed25519Derivation`) — not WalletCore `getKey`/`getAddressForCoin`.
    /// WalletCore's default Solana path is Trust (`m/44'/501'/0'`); custom
    /// path strings via `getKey` have historically produced the wrong
    /// address while the UI still checkmarked Phantom.
    ///
    /// Passphrase wallets **must** supply the real BIP-39 passphrase
    /// (empty string is only valid when `hasPassphrase == false`).
    static func resolve(
        walletId: UUID,
        walletKind: WalletKind,
        hasPassphrase: Bool,
        passphrase: String,
        style: SolanaPathStyle,
        account: Int,
        database: AppDatabase
    ) throws -> SolanaReceivePathSwitchResult {
        guard walletKind == .created || walletKind == .importedMnemonic else {
            throw SolanaReceivePathSwitchError.unsupportedWallet
        }
        if hasPassphrase, passphrase.isEmpty {
            throw SolanaReceivePathSwitchError.passphraseWallet
        }
        guard let words = try WalletSecretPersistence.loadMnemonic(for: walletId, database: database),
              !words.isEmpty else {
            throw SolanaReceivePathSwitchError.missingMnemonic
        }

        let normalizedWords = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty else {
            throw SolanaReceivePathSwitchError.missingMnemonic
        }
        guard let accountIndex = UInt32(exactly: account) else {
            throw SolanaReceivePathSwitchError.invalidMnemonic
        }

        let resolvedPassphrase = hasPassphrase ? passphrase : ""
        let seed = BIP39.deriveSeed(words: normalizedWords, passphrase: resolvedPassphrase)
        let path = style.derivationPath(account: account)
        let address: String
        switch style {
        case .phantom:
            address = try Ed25519Derivation.solanaPhantomAddress(seed: seed, account: accountIndex)
        case .trustWallet:
            address = try Ed25519Derivation.solanaTrustWalletAddress(seed: seed, account: accountIndex)
        }
        guard !address.isEmpty else { throw SolanaReceivePathSwitchError.invalidMnemonic }
        return SolanaReceivePathSwitchResult(
            style: style,
            account: account,
            derivationPath: path,
            address: address
        )
    }
}

/// BIP-39 passphrase entry for Solana path switch on passphrase wallets.
private struct ReceiveSolanaPassphraseSheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 40, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(UniColors.Brand.mark)
                        .accessibilityHidden(true)
                    UniBody(
                        text: "This wallet has a passphrase. Enter it to derive Phantom and Trust Wallet Solana paths — it never leaves this iPhone.",
                        color: UniColors.Text.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                UniTextField(
                    placeholder: "Passphrase",
                    text: $passphrase,
                    isSecure: true
                )
                Spacer()
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .navigationTitle("Passphrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }.tint(UniColors.Button.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Continue") { onSubmit(passphrase) }.tint(UniColors.Button.text)
                        .fontWeight(.semibold)
                        .disabled(passphrase.isEmpty)
                }
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

    /// Standard account-0 / receive-0 path for this address type.
    var accountZeroPath: String {
        switch self {
        case .bip86: return "m/86'/0'/0'/0/0"
        case .bip84: return "m/84'/0'/0'/0/0"
        case .bip49: return "m/49'/0'/0'/0/0"
        case .bip44: return "m/44'/0'/0'/0/0"
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
        database: AppDatabase
    ) -> BitcoinReceiveAddressResolution {
        if let wallet,
           wallet.hasPassphrase == false,
           let words = try? WalletSecretPersistence.loadMnemonic(for: wallet.id, database: database),
           !words.isEmpty,
           let result = resolveMnemonic(words) {
            return result
        }

        if let wallet,
           let privateKey = try? WalletSecretPersistence.loadPrivateKey(for: wallet.id, database: database),
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

        // Mainnet uncompressed WIF starts with "5" (payload 33 bytes, no
        // compression flag). Only P2PKH/legacy is valid — no type picker.
        if decoded.isUncompressedWIF {
            guard let address = p2pkhAddress(privateKey: privateKey, compressed: false) else { return nil }
            return BitcoinReceiveAddressResolution(
                choices: [BitcoinReceiveAddressChoice(type: .bip44, address: address)],
                defaultType: .bip44
            )
        }

        // Compressed WIF (K/L) or hex: multiple forms possible; default BIP84.
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
        let defaultType: BitcoinReceiveAddressType =
            choices.contains(where: { $0.type == .bip84 }) ? .bip84 : (choices.first?.type ?? .bip84)
        return BitcoinReceiveAddressResolution(choices: choices, defaultType: defaultType)
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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") ? String(trimmed.dropFirst(2)) : trimmed
        if hex.count == 64,
           hex.allSatisfy(\.isHexDigit),
           let data = Data(apertureReceiveBitcoinHex: hex),
           PrivateKey.isValid(data: data, curve: CoinType.bitcoin.curve) {
            return (data, false)
        }

        guard let payload = WalletCore.Base58.decode(string: trimmed) else { return nil }
        // Uncompressed mainnet WIF: version 0x80 + 32 key bytes (Base58 usually
        // starts with "5"). Compressed: + trailing 0x01 (usually K/L).
        let isUncompressed = payload.count == 33
        let isCompressed = payload.count == 34 && payload.last == 0x01
        guard payload.first == 0x80, isUncompressed || isCompressed else { return nil }
        let keyData = Data(payload.dropFirst().prefix(32))
        guard PrivateKey.isValid(data: keyData, curve: CoinType.bitcoin.curve) else { return nil }
        // Prefer payload shape; also treat leading "5" as uncompressed WIF.
        let looksUncompressedWIF = isUncompressed || trimmed.hasPrefix("5")
        return (keyData, looksUncompressedWIF && !isCompressed)
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
