import SwiftUI

// MARK: - Title

/// Largest title in the type ramp — onboarding hero, screen heros.
/// Accepts `LocalizedStringKey` so every call site flows through the
/// String Catalog (Rule #9). String literals at call sites still work
/// because `LocalizedStringKey: ExpressibleByStringLiteral`. For truly
/// runtime, non-localizable strings (an asset ticker, a user-typed name),
/// use `Text(verbatim:)` at the call site rather than this component.
struct UniLargeTitle: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.primary

    var body: some View {
        Text(text)
            .font(UniTypography.largeTitle)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UniTitle: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.primary

    var body: some View {
        Text(text)
            .font(UniTypography.title1)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UniTitle2: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.primary

    var body: some View {
        Text(text)
            .font(UniTypography.title2)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UniHeadline: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.primary

    var body: some View {
        Text(text)
            .font(UniTypography.headline)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Subtitle / Body / Caption

struct UniSubtitle: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.secondary

    var body: some View {
        Text(text)
            .font(UniTypography.subheadline)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UniBody: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.primary
    var emphasized: Bool = false

    var body: some View {
        Text(text)
            .font(emphasized ? UniTypography.bodyEmphasized : UniTypography.body)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UniCallout: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.secondary

    var body: some View {
        Text(text)
            .font(UniTypography.callout)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UniFootnote: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.tertiary

    var body: some View {
        Text(text)
            .font(UniTypography.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UniCaption: View {
    let text: LocalizedStringKey
    var alignment: TextAlignment = .leading
    var color: Color = UniColors.Text.tertiary

    var body: some View {
        Text(text)
            .font(UniTypography.caption1)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
