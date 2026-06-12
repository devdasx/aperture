import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CryptoKit

/// The wallet-avatar customisation sheet — the 2026-06-09 v3 rewrite
/// per the design handoff at
/// `/Users/thuglifex/Downloads/design_handoff_wallet_avatars/`. A live
/// 96pt preview of the user's chosen identity sits at the top;
/// underneath, a horizontal gradient swatch row (12 options) + a
/// three-segment Symbol / Letter / Upload toggle. The Symbol grid
/// shows the iris + 30 Lucide marks; the Letter grid shows 12
/// curated letters/digits (+ the wallet's own initial when not in
/// the curated set); the Upload tab presents a file picker that
/// accepts an `.svg`, sanitizes it through `SVGSanitizer`, and
/// surfaces a White / Keep colours sub-toggle. Save commits the
/// staged spec; Cancel / swipe-to-dismiss discards.
///
/// **Why staging, not live commits.** The pre-2026-06-09 picker
/// committed every tap straight through `@Query` reactivity — a
/// stylistic mistake in retrospect. The user couldn't preview a
/// gradient + glyph combo without writing it; if they didn't like
/// the result they had to walk back. The picker stages every edit
/// in `@State` and lands them only on Save — Apple's iOS Settings →
/// Appearance pattern. The user explores freely; commitment is
/// explicit.
///
/// **Per Rule #15:** `NavigationStack`-rooted, `navigationTitle("Wallet icon")`,
/// `.navigationBarTitleDisplayMode(.inline)`. Cancel sits in
/// `.topBarLeading`; Save lives at the bottom of the content as a
/// `UniButton(.primary)` because it's the commit action (Rule #19).
///
/// **Rule #4 carries no exception here.** Every color flows through
/// `UniColors.WalletAvatar.gradientStops(for:)` and other named roles.
/// The Upload tab's inline error messages flow through `UniColors.
/// Status.warningForeground` / `Status.errorForeground` — no hex.
///
/// **Rule #9 (i18n).** Every string the user reads is a
/// `LocalizedStringKey` or `Text(...)` with a localized key. New v3
/// strings: "Upload", "Choose SVG file", "Choose different file",
/// "White", "Keep colours", error messages.
struct WalletIconPickerSheet: View {
    let walletId: UUID

    @Query private var matches: [WalletRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Staged spec (commit on Save, discard on Cancel)

    /// The gradient the user is currently previewing.
    @State private var stagedGradient: WalletAvatarGradient = .graphite
    /// Whether the user is currently editing the glyph grid, the
    /// letter grid, or the upload sheet.
    @State private var stagedSymbolType: WalletAvatarSpec.WalletAvatarSymbolType = .mono
    /// The glyph the user has chosen when `stagedSymbolType == .glyph`.
    @State private var stagedGlyph: WalletAvatarGlyph = .iris
    /// The letter the user has chosen when `stagedSymbolType == .mono`.
    @State private var stagedMonogram: String = "W"
    /// The sanitized SVG text staged from an Upload session. Set when
    /// the user picks a file and `SVGSanitizer.sanitize(_:)` succeeds;
    /// cleared when the user picks a different file or switches away
    /// from Upload.
    @State private var stagedCustomSvg: String?
    /// The display name of the staged file (for the "Selected: foo.svg"
    /// affordance). Truncated mid-name for long file names.
    @State private var stagedFileName: String?
    /// The tint choice for the staged SVG. Defaults to `.white` per
    /// the v3 brief.
    @State private var stagedCustomTint: WalletAvatarSpec.CustomTint = .white
    /// The most recent file-importer error, surfaced inline under the
    /// upload button. Cleared whenever the user picks a new file.
    @State private var uploadError: UploadError?
    /// Whether the file importer is presented.
    @State private var isShowingFileImporter: Bool = false
    /// Whether the staged spec has been initialised from the wallet
    /// record. Guards against re-seeding on every body re-render.
    @State private var didSeed: Bool = false
    /// Bumped on a successful file pick + sanitize. Drives
    /// `.uniHaptic(.selection, trigger:)` on the upload area so the
    /// user feels the success of the pick.
    @State private var uploadSuccessTick: Int = 0
    /// Bumped on a file-pick failure. Drives the warning haptic on
    /// the same surface.
    @State private var uploadWarningTick: Int = 0

    init(walletId: UUID) {
        self.walletId = walletId
        _matches = Query(filter: #Predicate<WalletRecord> { $0.id == walletId })
    }

    private var wallet: WalletRecord? { matches.first }

    // MARK: - Upload error model

    /// Inline error states the picker surfaces when the user picks a
    /// file. Each maps to a localized message under the upload button.
    enum UploadError: Equatable {
        case readFailed
        case notSVG
        case tooLarge(actualKB: Int)
        case sanitizedToEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let wallet {
                    content(wallet)
                } else {
                    missing
                }
            }
            .navigationTitle("Wallet icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { seedIfNeeded() }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [UTType.svg],
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ wallet: WalletRecord) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.xl) {
                    livePreview(wallet)
                    colorSection
                    symbolSection
                    tipFootnote
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.xl)
            }
            saveBar(wallet)
        }
    }

    // MARK: - Live preview

    /// The 96pt avatar at the top of the sheet — the user's chosen
    /// gradient + glyph or monogram or custom SVG, animated as they
    /// tap. The wallet name underneath is rendered verbatim (user-
    /// supplied content); the badge derives from the wallet's kind
    /// and never changes via this sheet.
    @ViewBuilder
    private func livePreview(_ wallet: WalletRecord) -> some View {
        VStack(spacing: UniSpacing.s) {
            // For `.custom` specs we render the live preview through a
            // dedicated `WKWebView`-backed `CustomSvgLivePreview` so
            // every keystroke / tint flip reflects immediately —
            // there's no PNG cache to flush, and the persisted cache
            // (`WalletCustomSvgRenderer.cachedImage`) only updates
            // on Save commit. For glyph/mono the canonical
            // `WalletAvatar(spec:size:)` is used directly.
            if stagedSymbolType == .custom, let svg = stagedCustomSvg {
                WalletAvatarCustomLivePreview(
                    gradient: stagedGradient,
                    svg: svg,
                    tint: stagedCustomTint,
                    badge: WalletAvatarBadge.derive(from: wallet.kind),
                    diameter: WalletAvatar.Size.editor.diameter
                )
            } else {
                WalletAvatar(
                    spec: stagedSpec(for: wallet),
                    size: .editor
                )
                .animation(.smooth(duration: 0.18), value: stagedGradient)
                .animation(.smooth(duration: 0.18), value: stagedSymbolType)
                .animation(.smooth(duration: 0.18), value: stagedGlyph)
                .animation(.smooth(duration: 0.18), value: stagedMonogram)
            }

            Text(verbatim: wallet.name)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Colour section

    /// A horizontal scrollable row of 12 gradient swatches, each a
    /// 40pt circle filled with its gradient. The selected swatch
    /// carries a 2pt ink ring offset 4pt outside the swatch — the
    /// classic iOS selection mark, restrained.
    @ViewBuilder
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            sectionLabel("Colour")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UniSpacing.s) {
                    ForEach(WalletAvatarGradient.allCases, id: \.self) { gradient in
                        gradientSwatch(gradient)
                    }
                }
                .padding(.horizontal, 4) // breathing room for the selection ring
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func gradientSwatch(_ gradient: WalletAvatarGradient) -> some View {
        let isActive = (gradient == stagedGradient)
        Button {
            stagedGradient = gradient
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: UniColors.WalletAvatar.gradientStops(for: gradient),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 40, height: 40)
                Circle()
                    .stroke(
                        isActive ? UniColors.Text.primary : Color.clear,
                        lineWidth: 2
                    )
                    .frame(width: 48, height: 48)
            }
            .frame(width: 52, height: 52, alignment: .center)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: isActive)
        .accessibilityLabel(Text(verbatim: gradient.rawValue.capitalized))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Symbol / Letter / Upload section

    /// The segmented Symbol / Letter / Upload switcher + the body
    /// underneath. The body flips when the user changes the
    /// segmented control — glyph grid, letter grid, or upload area.
    @ViewBuilder
    private var symbolSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            Picker("Symbol or Letter or Upload", selection: $stagedSymbolType) {
                Text("Symbol").tag(WalletAvatarSpec.WalletAvatarSymbolType.glyph)
                Text("Letter").tag(WalletAvatarSpec.WalletAvatarSymbolType.mono)
                Text("Upload").tag(WalletAvatarSpec.WalletAvatarSymbolType.custom)
            }
            .pickerStyle(.segmented)
            .uniHaptic(.selection, trigger: stagedSymbolType)

            switch stagedSymbolType {
            case .glyph:
                glyphGrid
            case .mono:
                letterGrid
            case .custom:
                uploadArea
            }
        }
    }

    /// The 6-column glyph grid. 31 cells — iris first (the brand
    /// pinwheel), then the 30 Lucide marks in tokens.json order. Each
    /// cell is a 1:1 rounded rect (radius 14) with the glyph rendered
    /// in ink on a soft fill; the selected cell carries an ink stroke
    /// 2pt wide.
    @ViewBuilder
    private var glyphGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: UniSpacing.s), count: 6)
        LazyVGrid(columns: columns, spacing: UniSpacing.s) {
            ForEach(WalletAvatarGlyph.allCases, id: \.self) { glyph in
                glyphCell(glyph)
            }
        }
    }

    @ViewBuilder
    private func glyphCell(_ glyph: WalletAvatarGlyph) -> some View {
        let isActive = (glyph == stagedGlyph)
        Button {
            stagedGlyph = glyph
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(UniColors.Fill.secondary)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isActive ? UniColors.Text.primary : Color.clear,
                        lineWidth: 2
                    )
                // The glyph view renders in white, so for the picker
                // grid we render it via a tiny ink-tinted Canvas
                // mirror of the same paths (see GlyphCellRender below).
                GlyphCellRender(glyph: glyph)
                    .frame(width: 28, height: 28)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: isActive)
        .accessibilityLabel(Text(verbatim: glyph.rawValue.capitalized))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// The 6-column letter grid. We surface the 12 most-likely
    /// letters/digits — a curated subset rather than the full
    /// alphabet, per Rule #2 §A.6 (less, but better). If the
    /// wallet's name starts with a letter outside this set, we
    /// include it as a 13th cell at the front so the user can
    /// always pick their own initial without typing.
    @ViewBuilder
    private var letterGrid: some View {
        let curated: [String] = ["M", "A", "S", "T", "V", "W", "1", "2", "3", "4", "5", "6"]
        let walletInitial: String? = wallet.flatMap {
            let first = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).first
            return first.map { String($0).uppercased() }
        }
        let allLetters: [String] = {
            guard let initial = walletInitial, !curated.contains(initial) else {
                return curated
            }
            return [initial] + curated
        }()

        let columns = Array(repeating: GridItem(.flexible(), spacing: UniSpacing.s), count: 6)
        LazyVGrid(columns: columns, spacing: UniSpacing.s) {
            ForEach(allLetters, id: \.self) { letter in
                letterCell(letter)
            }
        }
    }

    @ViewBuilder
    private func letterCell(_ letter: String) -> some View {
        let isActive = (letter == stagedMonogram)
        Button {
            stagedMonogram = letter
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(UniColors.Fill.secondary)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isActive ? UniColors.Text.primary : Color.clear,
                        lineWidth: 2
                    )
                Text(verbatim: letter)
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .tracking(-0.5)
                    .foregroundStyle(UniColors.Text.primary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: isActive)
        .accessibilityLabel(Text(verbatim: letter))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Upload tab

    /// The Upload tab: a "Choose SVG file" button, an inline staged-
    /// file affordance once a file lands (with file name + "Choose
    /// different file" link), a White / Keep colours subtoggle, and
    /// inline error messages for invalid input.
    @ViewBuilder
    private var uploadArea: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            if let fileName = stagedFileName, stagedCustomSvg != nil {
                stagedFileRow(fileName: fileName)
                tintToggle
            } else {
                chooseFileButton
                if let error = uploadError {
                    uploadErrorRow(error)
                }
            }

            uploadHint
        }
        .uniHaptic(.selection, trigger: uploadSuccessTick)
        .uniHaptic(.warning, trigger: uploadWarningTick)
    }

    @ViewBuilder
    private var chooseFileButton: some View {
        UniButton(
            title: "Choose SVG file",
            variant: .secondary
        ) {
            uploadError = nil
            isShowingFileImporter = true
        }
    }

    @ViewBuilder
    private func stagedFileRow(fileName: String) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "doc.text")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
            Text(verbatim: truncate(fileName, max: 28))
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: UniSpacing.s)
            Button {
                uploadError = nil
                isShowingFileImporter = true
            } label: {
                Text("Choose different file")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.link)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, UniSpacing.s)
        .padding(.horizontal, UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(UniColors.Fill.secondary)
        )
    }

    @ViewBuilder
    private var tintToggle: some View {
        Picker("Tint", selection: $stagedCustomTint) {
            Text("White").tag(WalletAvatarSpec.CustomTint.white)
            Text("Keep colours").tag(WalletAvatarSpec.CustomTint.original)
        }
        .pickerStyle(.segmented)
        .uniHaptic(.selection, trigger: stagedCustomTint)
    }

    @ViewBuilder
    private func uploadErrorRow(_ error: UploadError) -> some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Status.warningForeground)
            Text(uploadErrorMessage(error))
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Status.warningForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One-sentence localized message per error case. Rule #16 §A.6
    /// honesty: the message states exactly what's wrong, no marketing
    /// dilution.
    private func uploadErrorMessage(_ error: UploadError) -> LocalizedStringKey {
        switch error {
        case .readFailed:
            return "Couldn\u{2019}t read that file."
        case .notSVG:
            return "This isn\u{2019}t a valid SVG."
        case .tooLarge:
            return "File too large \u{2014} max 50 KB."
        case .sanitizedToEmpty:
            return "Nothing renderable left after sanitizing."
        }
    }

    @ViewBuilder
    private var uploadHint: some View {
        Text("SVG only \u{00B7} keep it simple and single-shape for best results.")
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Text.tertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Truncate a file name to ~28 characters with a middle ellipsis.
    private func truncate(_ name: String, max: Int) -> String {
        guard name.count > max else { return name }
        let head = name.prefix(max / 2)
        let tail = name.suffix(max / 2 - 1)
        return "\(head)\u{2026}\(tail)"
    }

    // MARK: - Tip footnote

    @ViewBuilder
    private var tipFootnote: some View {
        Text("Tip: leave it on \u{201C}Letter\u{201D} to auto-use the wallet\u{2019}s initial.")
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Text.tertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Save bar

    /// A floating Save button anchored to the bottom of the sheet,
    /// inside a `GlassEffectContainer` (per Rule #2 §B.5) so the
    /// commit affordance lives on the system's functional layer.
    /// Disabled when the user is in Upload mode but hasn't picked a
    /// file yet — committing a `.custom` spec with no SVG would
    /// fall back to a monogram on render, which silently confuses
    /// the user about what they just saved.
    @ViewBuilder
    private func saveBar(_ wallet: WalletRecord) -> some View {
        let canSave: Bool = {
            if stagedSymbolType == .custom {
                return stagedCustomSvg != nil
            }
            return true
        }()
        GlassEffectContainer(spacing: 0) {
            UniButton(
                title: "Save",
                variant: .primary,
                isEnabled: canSave
            ) {
                commit(wallet)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.s)
            .padding(.top, UniSpacing.s)
        }
    }

    // MARK: - Section label

    @ViewBuilder
    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(UniTypography.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(UniColors.Text.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    // MARK: - File pick handling

    /// Process a `fileImporter` result. Reads the file, sanitizes the
    /// contents, surfaces an inline error if any step fails.
    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            uploadError = .readFailed
            return
        case .success(let urls):
            guard let url = urls.first else {
                uploadError = .readFailed
                return
            }
            // Security-scoped resource — the system grants temporary
            // access; we open / close the scope explicitly.
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    uploadError = .notSVG
                    uploadWarningTick &+= 1
                    return
                }
                let sanitized = try SVGSanitizer.sanitize(text)
                stagedCustomSvg = sanitized
                stagedFileName = url.lastPathComponent
                uploadError = nil
                uploadSuccessTick &+= 1
            } catch let SVGSanitizer.SanitizeError.tooLarge(actualBytes, _) {
                uploadError = .tooLarge(actualKB: actualBytes / 1024)
                uploadWarningTick &+= 1
            } catch SVGSanitizer.SanitizeError.notSVG {
                uploadError = .notSVG
                uploadWarningTick &+= 1
            } catch SVGSanitizer.SanitizeError.sanitizedToEmpty {
                uploadError = .sanitizedToEmpty
                uploadWarningTick &+= 1
            } catch {
                uploadError = .readFailed
                uploadWarningTick &+= 1
            }
        }
    }

    // MARK: - Seeding

    /// Initialise the staged spec from the wallet's current persisted
    /// avatar. Runs once on first appear via `didSeed`.
    private func seedIfNeeded() {
        guard !didSeed, let wallet else { return }
        let current = wallet.avatarSpec
        stagedGradient = current.gradient
        stagedSymbolType = current.symbolType
        stagedGlyph = current.glyph ?? .iris
        stagedMonogram = current.monogram ?? String(wallet.name.prefix(1)).uppercased()
        if stagedMonogram.isEmpty { stagedMonogram = "W" }
        // Seed custom-SVG state when the wallet's persisted spec is
        // `.custom`. The picker can either keep that mode (no upload
        // friction on re-edit) or switch to a different mode (then
        // the existing customSvg stays staged until Save commits the
        // new mode).
        if let svg = current.customSvg {
            stagedCustomSvg = svg
            stagedCustomTint = current.customTint ?? .white
            stagedFileName = String(localized: "Previously uploaded")
        }
        didSeed = true
    }

    // MARK: - Spec composition

    /// The currently-staged spec, used both for the live preview and
    /// for the Save commit. Always includes the wallet's derived
    /// badge so the preview matches what the user will see on the
    /// home / list / switcher surfaces.
    private func stagedSpec(for wallet: WalletRecord) -> WalletAvatarSpec {
        switch stagedSymbolType {
        case .glyph:
            return WalletAvatarSpec(
                gradient: stagedGradient,
                symbolType: .glyph,
                glyph: stagedGlyph,
                monogram: nil,
                customSvg: nil,
                customTint: nil,
                badge: WalletAvatarBadge.derive(from: wallet.kind)
            )
        case .mono:
            return WalletAvatarSpec(
                gradient: stagedGradient,
                symbolType: .mono,
                glyph: nil,
                monogram: stagedMonogram,
                customSvg: nil,
                customTint: nil,
                badge: WalletAvatarBadge.derive(from: wallet.kind)
            )
        case .custom:
            // If the user has Upload selected but hasn't picked a
            // file yet, the live preview falls back to glyph(iris)
            // — Save is disabled in this state so this is preview-
            // only.
            if let svg = stagedCustomSvg {
                return WalletAvatarSpec(
                    gradient: stagedGradient,
                    symbolType: .custom,
                    glyph: nil,
                    monogram: nil,
                    customSvg: svg,
                    customTint: stagedCustomTint,
                    badge: WalletAvatarBadge.derive(from: wallet.kind)
                )
            } else {
                return WalletAvatarSpec(
                    gradient: stagedGradient,
                    symbolType: .glyph,
                    glyph: .iris,
                    monogram: nil,
                    customSvg: nil,
                    customTint: nil,
                    badge: WalletAvatarBadge.derive(from: wallet.kind)
                )
            }
        }
    }

    // MARK: - Commit

    /// Write the staged spec directly to the wallet record on the
    /// view's `@Environment(\.modelContext)` and save.
    ///
    /// **Why direct mutation, not `WalletRepository.updateAvatar(...)`
    /// (2026-06-09 v2).** The first cut commit routed through the
    /// `@ModelActor`-isolated repository. That writes through the
    /// actor's *own* `ModelContext` and saves there — the change
    /// reaches the store, but SwiftData's cross-context merge does
    /// NOT reliably propagate the update into the main-context
    /// `@Query` snapshots that `MainTabView` and `WalletSwitcherSheet`
    /// read from. The user observed the symptom on Thuglife
    /// `databaseSequenceNumber 8580`: their custom black + iris
    /// identity showed on `WalletDetailView`'s hero (which re-reads
    /// the same `@Model` reference) but `MainTabView`'s bottom-tab
    /// avatar kept rendering the `auto(name)` "W" monogram.
    ///
    /// Mutating the `@Model` object on the *view's* context (the
    /// SwiftUI main context, hooked into `@Query` reactivity for
    /// every observer) and saving there propagates immediately —
    /// the tab icon, the toolbar pill, the switcher rows, and the
    /// list rows all snap to the new spec on dismiss. The badge is
    /// re-derived from `kind` at the write site, matching the
    /// repository's contract.
    ///
    /// **Custom-SVG cache flush.** Before the SwiftData write we
    /// invalidate the cached PNG for this wallet so the next render
    /// produces fresh pixels reflecting the saved (gradient ×
    /// tint × svg) tuple. The async `renderAndCache(...)` populates
    /// the new PNG; subsequent body passes pick it up via
    /// `CustomSvgCachedView`'s `.task(id:)`.
    private func commit(_ wallet: WalletRecord) {
        let spec = stagedSpec(for: wallet)
        wallet.avatarGradient = spec.gradient.rawValue
        wallet.avatarSymbolType = spec.symbolType.rawValue
        wallet.avatarGlyph = spec.glyph?.rawValue
        wallet.avatarMonogram = spec.monogram
        wallet.avatarCustomSvg = spec.customSvg
        wallet.avatarCustomTint = spec.customTint?.rawValue
        wallet.avatarBadge = WalletAvatarBadge.derive(from: wallet.kind)?.rawValue
        wallet.updatedAt = Date()
        try? modelContext.save()

        // For `.custom` specs, invalidate + repopulate the cache so
        // the moment any view reads `cachedImage(walletId:)` it
        // either gets the freshly-saved pixels (fast path) or the
        // PNG is generated by the background `renderAndCache(...)`
        // task that `CustomSvgCachedView` kicks off on first render.
        if spec.symbolType == .custom, let svg = spec.customSvg {
            WalletCustomSvgRenderer.invalidate(walletId: wallet.id)
            let tint = spec.customTint ?? .white
            Task { @MainActor in
                try? await WalletCustomSvgRenderer.renderAndCache(
                    walletId: wallet.id,
                    svg: svg,
                    tint: tint
                )
            }
        } else {
            // If the user switched AWAY from `.custom`, evict the
            // stale PNG so disk doesn't accumulate orphans.
            WalletCustomSvgRenderer.invalidate(walletId: wallet.id)
        }

        // 2026-06-09 — mirror the wallet metadata into Keychain so the
        // user's chosen identity survives an app reinstall. See
        // `WalletManifestStore.swift` for the full rationale.
        WalletManifestStore.sync(from: modelContext)
        dismiss()
    }

    // MARK: - Missing fallback

    private var missing: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
            UniBody(
                text: "This wallet is no longer in the local store.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
        .frame(maxWidth: .infinity)
        .padding(UniSpacing.xl)
    }
}

// MARK: - Live preview for `.custom` specs
//
// The persisted `.custom` render goes through
// `WalletCustomSvgRenderer`'s disk cache; the picker's live preview
// can't use that path because the cache invalidates on Save and the
// preview needs to reflect every keystroke / tint flip immediately.
// So we render the live preview through a per-frame `WKWebView`
// snapshot wrapped inside the gradient-disc composition. This view
// only ever appears inside the picker — never on the main app
// surfaces — so the per-render snapshot cost is bounded to whatever
// the user is currently editing.

private struct WalletAvatarCustomLivePreview: View {
    let gradient: WalletAvatarGradient
    let svg: String
    let tint: WalletAvatarSpec.CustomTint
    let badge: WalletAvatarBadge?
    let diameter: CGFloat

    @State private var preview: UIImage?

    /// SHA-256 content digest (16 hex chars) of the staged SVG — NOT
    /// its byte count, which fails to re-render when an edit produces
    /// a same-length document.
    private var renderKey: String {
        let digest = SHA256.hash(data: Data(svg.utf8))
        let svgKey = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(gradient.rawValue)|\(tint.rawValue)|\(svgKey)"
    }

    var body: some View {
        ZStack {
            // Gradient disc — same five-layer composition as
            // `WalletAvatar`. We inline the layers here so the preview
            // doesn't depend on `WalletAvatar` honoring the `.custom`
            // branch with a UUID it doesn't have.
            Circle()
                .fill(
                    LinearGradient(
                        colors: UniColors.WalletAvatar.gradientStops(for: gradient),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.26), location: 0),
                            .init(color: Color.white.opacity(0.03), location: 0.6),
                            .init(color: Color.white.opacity(0.0),  location: 1)
                        ]),
                        center: UnitPoint(x: 0.34, y: 0.24),
                        startRadius: 0,
                        endRadius: diameter * 0.80
                    )
                )
                .frame(width: diameter, height: diameter)

            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: diameter * (48.0 / 100.0), height: diameter * (48.0 / 100.0))
            } else {
                WalletAvatarGlyphView(glyph: .iris, size: diameter).opacity(0.32)
            }

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.45),
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(0.5, diameter * 0.015)
                )
                .frame(width: diameter, height: diameter)

            if let badge {
                WalletAvatarBadgeOverlay(badge: badge, avatarDiameter: diameter)
                    .offset(
                        x: diameter * (78.0 / 100.0) - diameter / 2,
                        y: diameter * (78.0 / 100.0) - diameter / 2
                    )
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .task(id: renderKey) {
            // Use a one-shot snapshot off the same renderer, with a
            // throw-away UUID so the cache doesn't pollute the
            // persisted directory. The `defer` guarantees the scratch
            // PNG is evicted on EVERY exit path — success, render
            // failure, AND task cancellation (the user flipping
            // gradient/tint mid-render re-keys `.task(id:)`, which
            // cancels this body; without the defer the cancelled
            // path leaked the scratch file on disk).
            let scratchId = UUID()
            defer { WalletCustomSvgRenderer.invalidate(walletId: scratchId) }
            do {
                preview = try await WalletCustomSvgRenderer.renderAndCache(
                    walletId: scratchId,
                    svg: svg,
                    tint: tint
                )
            } catch {
                preview = nil
            }
        }
    }
}

// MARK: - Glyph cell render
//
// The `WalletAvatarGlyphView` renders the glyph in WHITE — the disc's
// inner mark color. Inside the picker grid the glyph sits on a soft
// gray fill, so it needs to render in ink instead. We use a tiny
// wrapper that draws the same paths in `Text.primary`. The glyph
// paths come from the same `lucidePaths()` source the avatar uses,
// so updates to the path data propagate to both renderers
// automatically.

private struct GlyphCellRender: View {
    let glyph: WalletAvatarGlyph

    var body: some View {
        Canvas { context, size in
            let outerScale = size.width / 100.0
            switch glyph {
            case .iris:
                drawIris(in: context, scale: outerScale)
            default:
                drawLucide(in: context, scale: outerScale)
            }
        }
    }

    /// Stroke the Lucide icon's paths in `UniColors.Text.primary` — the
    /// in-picker grid uses ink instead of white. The transform is the
    /// same `translate(28,28) scale(1.833)` the avatar renderer uses.
    private func drawLucide(in context: GraphicsContext, scale outerScale: CGFloat) {
        let inner = CGAffineTransform.identity
            .scaledBy(x: outerScale, y: outerScale)
            .translatedBy(x: 28, y: 28)
            .scaledBy(x: 1.833, y: 1.833)
        // The picker cell is smaller (~28pt), so a tiny stroke
        // reduction keeps the painted weight visually balanced
        // against the 96pt avatar preview above.
        let lineWidth: CGFloat = 1.8 * 1.833 * outerScale

        let segments = glyph.lucidePaths()
        for segment in segments {
            let transformed = segment.path.applying(inner)
            switch segment.style {
            case .stroke:
                context.stroke(
                    transformed,
                    with: .color(UniColors.Text.primary),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            case .fill:
                context.fill(transformed, with: .color(UniColors.Text.primary))
            }
        }
    }

    private func drawIris(in context: GraphicsContext, scale: CGFloat) {
        let bladeCount = 6
        let twist: Double = 0.18
        let centerX: Double = 50
        let centerY: Double = 50
        let outerR: Double = 30
        let innerR = outerR * 0.42
        let step = (2 * .pi) / Double(bladeCount)
        for k in 0..<bladeCount {
            let angle = Double(k) * step - .pi / 2
            let p1 = polar(cx: centerX, cy: centerY, r: outerR, a: angle)
            let p3 = polar(cx: centerX, cy: centerY, r: innerR, a: angle + step + twist)
            let opacity: Double = (k % 2 == 0) ? 0.80 : 0.96

            var path = Path()
            path.move(to: CGPoint(x: p1.x, y: p1.y))
            path.addArc(
                center: CGPoint(x: centerX, y: centerY),
                radius: outerR,
                startAngle: .radians(angle),
                endAngle: .radians(angle + step),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: p3.x, y: p3.y))
            path.closeSubpath()
            let scaled = path.applying(.init(scaleX: scale, y: scale))
            context.fill(scaled, with: .color(UniColors.Text.primary.opacity(opacity)))
        }
    }

    private func polar(cx: Double, cy: Double, r: Double, a: Double) -> CGPoint {
        CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
}

// MARK: - Lucide path data sharing
//
// The picker's `GlyphCellRender` calls `WalletAvatarGlyph.lucidePaths()`
// directly. That method is `internal` (declared in
// `WalletAvatarGlyph.swift`) so this file has access — the convention
// is that the picker is its only consumer in the target. If a third
// caller appears, the right move is to gate the access through a
// dedicated `enum GlyphPathSource` rather than widening the API.
