import SwiftUI
import UIKit

/// Settings → Advanced → Debug logs (user direction 2026-06-18: "add logs
/// for all actions running in the background … I should be able to copy them
/// from Settings and send them, so we can understand what's happening").
///
/// Renders `DebugLog`'s SESSION-WIDE timeline — the 30 s background
/// auto-refresh loop, the full refresh pipeline (every chain scan, RPC
/// round-trip, price batch, DB commit, with ms), every main-thread `body`
/// re-render with its cause, and every main-thread stall the watchdog
/// catches — as selectable monospaced text with a one-tap **Copy** so it can
/// be pasted and sent for analysis. **Refresh** re-reads the live log;
/// **Clear** empties it. (Unlike the old per-run view, this keeps the whole
/// session, so the moments leading up to a hitch are preserved.)
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
        .navigationTitle(Text("Debug logs"))
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
                    logText = DebugLog.shared.snapshotText()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(UniTypography.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    DebugLog.shared.clear()
                    didCopy = false
                    logText = DebugLog.shared.snapshotText()
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
            logText = DebugLog.shared.snapshotText()
        }
    }
}
