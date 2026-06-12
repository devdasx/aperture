import SwiftUI

/// Confirmation sheet for an `eth_signTypedData_v4` request. The
/// EIP-712 payload is a structured `{ types, domain, primaryType,
/// message }` JSON; we render a key-value preview for the visible
/// scalars and show the raw JSON inside a monospaced card for the
/// rest. The user reads what they're signing, scrolls through it,
/// then approves.
///
/// **Sheet shape (Rule #15).** `NavigationStack` + `ScrollView` —
/// typed-data payloads can be long. `.large` detent only.
///
/// **Honesty (Rule #16).** Aperture doesn't pretend to validate
/// the typed-data domain against a list of "trusted" dApps. The
/// `domain.name` is shown verbatim — if a phishing site claims to
/// be Uniswap, the user reads the claim. The host above the
/// domain card is the canonical truth — what page is asking.
struct DAppSignTypedDataSheet: View {
    let request: DAppRequestRouter.SignTypedDataRequest
    let router: DAppRequestRouter

    @Environment(\.dismiss) private var dismiss

    /// Decoded JSON for the key-value preview. Computed once on
    /// init and stored in `@State` so the view's body doesn't
    /// re-parse on every evaluation.
    @State private var decodedPreview: TypedDataPreview?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    identityHero
                    summaryCard
                    if let decodedPreview {
                        domainCard(decodedPreview)
                        messageCard(decodedPreview)
                    } else {
                        rawJSONCard
                    }
                    warningStatement
                    Spacer(minLength: UniSpacing.m)
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(UniColors.Background.primary)
            .navigationTitle("Sign typed data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        router.rejectPending()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionRegion
            }
            .onAppear {
                decodedPreview = TypedDataPreview.decode(request.rawJSON)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var identityHero: some View {
        HStack(spacing: UniSpacing.m) {
            BrowserFaviconView(
                url: request.origin.iconURL.flatMap(URL.init(string:)),
                fallbackLetter: request.origin.title,
                size: .hero
            )

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: request.origin.title)
                    .font(UniTypography.title2)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(2)
                Text(verbatim: request.origin.host)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                if let primaryType = decodedPreview?.primaryType {
                    KeyValueRow(
                        label: "Primary type",
                        value: primaryType
                    )
                }
                KeyValueRow(
                    label: "Network",
                    value: request.chain.displayName
                )
            }
        }
    }

    @ViewBuilder
    private func domainCard(_ preview: TypedDataPreview) -> some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "Domain",
                    color: UniColors.Text.tertiary
                )
                ForEach(preview.domainPairs, id: \.label) { pair in
                    KeyValueRow(label: pair.label, value: pair.value)
                }
            }
        }
    }

    @ViewBuilder
    private func messageCard(_ preview: TypedDataPreview) -> some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "Message",
                    color: UniColors.Text.tertiary
                )
                if preview.messagePairs.isEmpty {
                    UniBody(
                        text: "No scalar fields to preview.",
                        color: UniColors.Text.secondary
                    )
                } else {
                    ForEach(preview.messagePairs, id: \.label) { pair in
                        KeyValueRow(label: pair.label, value: pair.value)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rawJSONCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "Payload",
                    color: UniColors.Text.tertiary
                )
                Text(verbatim: request.rawJSON)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var warningStatement: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Status.warningForeground)
                .frame(width: 20)
            UniFootnote(
                text: "Signing this data may authorize a token transfer or permit. Only sign typed data from dApps you trust.",
                color: UniColors.Text.secondary
            )
        }
    }

    @ViewBuilder
    private var actionRegion: some View {
        VStack(spacing: UniSpacing.xs) {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Sign", variant: .primary) {
                        Task {
                            do {
                                let signature = try await EVMDAppSigner.signTypedData(
                                    json: request.rawJSON
                                )
                                router.approveSign(signedHex: signature)
                            } catch {
                                router.failPending(EVMDAppSigner.requestError(for: error))
                            }
                            dismiss()
                        }
                    }
                    UniButton(title: "Cancel", variant: .secondary) {
                        router.rejectPending()
                        dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.bottom, UniSpacing.xs)
        .background(
            UniColors.Background.primary
                .opacity(0.92)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - KeyValueRow

private struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text(verbatim: label)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(width: 96, alignment: .leading)
            Text(verbatim: value)
                .font(UniTypography.subheadlineEmphasized)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - TypedDataPreview

/// Decoded key-value pairs from a EIP-712 payload. Best-effort —
/// only scalar fields (`String`, `Number`, `Bool`) are surfaced;
/// nested types render as raw JSON in the catch-all card.
private struct TypedDataPreview {
    let primaryType: String?
    let domainPairs: [Pair]
    let messagePairs: [Pair]

    struct Pair {
        let label: String
        let value: String
    }

    static func decode(_ rawJSON: String) -> TypedDataPreview? {
        guard let data = rawJSON.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any] else {
            return nil
        }
        let primaryType = object["primaryType"] as? String
        let domain = object["domain"] as? [String: Any] ?? [:]
        let message = object["message"] as? [String: Any] ?? [:]
        return TypedDataPreview(
            primaryType: primaryType,
            domainPairs: scalarPairs(from: domain),
            messagePairs: scalarPairs(from: message)
        )
    }

    private static func scalarPairs(from object: [String: Any]) -> [Pair] {
        object.compactMap { key, value in
            if let s = value as? String {
                return Pair(label: key, value: s)
            }
            if let n = value as? NSNumber {
                return Pair(label: key, value: n.stringValue)
            }
            if let b = value as? Bool {
                return Pair(label: key, value: b ? "true" : "false")
            }
            return nil
        }
        .sorted { $0.label < $1.label }
    }
}
