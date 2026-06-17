import SwiftUI

/// Wallet-home banner for a swap running in `SwapBackgroundManager` — shown
/// directly under the Send / Receive actions (user direction 2026-06-17).
///
/// When a user taps "Run in the background" on the swap screen, the swap keeps
/// going (approval → broadcast → confirm) and this banner is how they see it:
/// a live "Swapping USDC → ETH · Approving" strip with a spinner, tappable to
/// reopen the full status. A finished job (done / reverted / failed) lingers
/// with its outcome and a dismiss control.
struct SwapBackgroundBanner: View {
    let job: SwapJob
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            leadingGlyph
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: detail)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: UniSpacing.s)
            trailing
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(tint.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .stroke(tint.stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
        .onTapGesture { onOpen() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title). \(detail)"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Leading glyph (spinner while running, status icon when done)

    @ViewBuilder
    private var leadingGlyph: some View {
        switch job.status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(UniColors.Status.infoForeground)
        case .done:
            Image(systemName: job.didConfirm ? "checkmark.circle.fill"
                              : (job.didRevert ? "xmark.octagon.fill" : "arrow.left.arrow.right.circle.fill"))
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint.foreground)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 21, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint.foreground)
        }
    }

    /// Running → a chevron (tap to open). Finished → a dismiss control.
    @ViewBuilder
    private var trailing: some View {
        if job.status == .running {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        } else {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
    }

    // MARK: - Copy

    private var pair: String {
        "\(job.summary.quote.fromToken.symbol) → \(job.summary.quote.toToken.symbol)"
    }

    private var title: String {
        switch job.status {
        case .running:
            return job.isBridge ? "Bridging \(pair)" : "Swapping \(pair)"
        case .done:
            if job.didConfirm { return job.isBridge ? "Bridge submitted" : "Swap complete" }
            if job.didRevert { return job.isBridge ? "Bridge didn't go through" : "Swap didn't go through" }
            return "Submitted"
        case .failed:
            return job.isBridge ? "Bridge failed" : "Swap failed"
        }
    }

    private var detail: String {
        switch job.status {
        case .running:
            return phaseLabel
        case .done:
            if job.didConfirm {
                return job.isBridge ? "\(pair) — arriving on the destination chain" : "\(pair) — done"
            }
            if job.didRevert { return "\(pair) — your funds didn't move" }
            return "\(pair) — submitted on-chain"
        case .failed:
            return "\(pair) — tap for details"
        }
    }

    /// Honest, human label for the live execution phase.
    private var phaseLabel: String {
        switch job.execPhase {
        case .preparing:           return "Preparing…"
        case .checkingApproval:    return "Checking approval…"
        case .approving:           return "Approving \(job.summary.quote.fromToken.symbol)…"
        case .confirmingApproval:  return "Confirming approval…"
        case .signing:             return "Signing…"
        case .broadcasting:        return "Submitting…"
        case .confirming:          return "Confirming on-chain…"
        }
    }

    // MARK: - Tint by status

    private struct Tint { let background: Color; let foreground: Color; let stroke: Color }

    private var tint: Tint {
        switch job.status {
        case .running:
            return Tint(background: UniColors.Status.infoBackground,
                        foreground: UniColors.Status.infoForeground,
                        stroke: UniColors.Status.infoStroke)
        case .done where job.didRevert:
            return Tint(background: UniColors.Status.errorBackground,
                        foreground: UniColors.Status.errorForeground,
                        stroke: UniColors.Status.errorStroke)
        case .done:
            return Tint(background: UniColors.Status.successBackground,
                        foreground: UniColors.Status.successForeground,
                        stroke: UniColors.Status.successStroke)
        case .failed:
            return Tint(background: UniColors.Status.warningBackground,
                        foreground: UniColors.Status.warningForeground,
                        stroke: UniColors.Status.warningStroke)
        }
    }
}
