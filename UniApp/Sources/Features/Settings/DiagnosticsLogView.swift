import SwiftUI
import UIKit

/// Settings → Advanced → Refresh diagnostics (user direction 2026-06-17).
///
/// Renders `RefreshPerfLog`'s timeline of the most recent refresh —
/// every chain's balance + history API, every RPC round-trip, every DB
/// commit, with millisecond durations and a "slowest actions" summary —
/// as selectable monospaced text with a one-tap **Copy** so it can be
/// pasted for latency analysis. **Refresh** re-reads the log (after a
/// pull-to-refresh on the wallet screen); **Clear** empties it.
struct DiagnosticsLogView: View {

    @State private var logText: String = ""
    @State private var didCopy: Bool = false

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(logText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(UniColors.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(UniSpacing.m)
        }
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Refresh diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logText
                    didCopy = true
                    UniHapticEngine.shared.play(.signature(.irisSettle))
                } label: {
                    Label(
                        didCopy ? "Copied" : "Copy",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: UniSpacing.m) {
                Button {
                    didCopy = false
                    logText = RefreshPerfLog.shared.snapshotText()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(UniTypography.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    RefreshPerfLog.shared.clear()
                    didCopy = false
                    logText = RefreshPerfLog.shared.snapshotText()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(UniTypography.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(UniSpacing.m)
            .background(.ultraThinMaterial)
        }
        .onAppear {
            logText = RefreshPerfLog.shared.snapshotText()
        }
    }
}
