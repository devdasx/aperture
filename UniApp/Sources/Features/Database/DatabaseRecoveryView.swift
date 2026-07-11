import SwiftUI
import UIKit

/// Blocking full-screen surface after destructive DB recovery (BUG-020 / P0-001).
///
/// Never presents as a silent empty wallet home. The user must acknowledge
/// that prior data was quarantined (or that this session is ephemeral) before
/// the rest of the app is interactive.
struct DatabaseRecoveryView: View {
    let incident: DatabaseRecoveryIncident?
    let isEphemeralStore: Bool
    let onAcknowledged: () -> Void

    @State private var shareItems: [URL] = []
    @State private var isShowingShare = false
    @State private var isShowingTechnical = false
    @State private var exportError: String?

    private var quarantineURL: URL? {
        if let path = incident?.quarantineDirectoryPath, !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return DatabaseRecoveryIncident.latestQuarantineDirectory(near: AppDatabase.shared.storeURL)
    }

    private var hasExportableBackup: Bool {
        guard let quarantineURL else { return false }
        return !DatabaseRecoveryIncident.exportableFiles(in: quarantineURL).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    header
                    explanation
                    if hasExportableBackup {
                        exportCard
                    }
                    if isEphemeralStore {
                        ephemeralWarning
                    }
                    technicalDetails
                    Spacer(minLength: UniSpacing.xl)
                    actions
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.xl)
                .padding(.bottom, UniSpacing.xxl)
            }
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Wallet data recovery")
                        .font(UniTypography.headline)
                        .foregroundStyle(UniColors.Text.primary)
                }
            }
        }
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $isShowingShare) {
            DatabaseRecoveryShareSheet(items: shareItems)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Image(systemName: isEphemeralStore ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.xmark")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(UniColors.Text.secondary)
                .accessibilityHidden(true)

            Text(isEphemeralStore
                 ? "Permanent storage is unavailable"
                 : "Wallet data could not be verified")
                .font(UniTypography.title2)
                .foregroundStyle(UniColors.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text(isEphemeralStore
                 ? "Aperture could not open its normal on-device database. This session will not keep wallets after the app restarts or the system clears temporary files."
                 : "Aperture found a problem with the wallet database on this device. Your previous data was moved to a backup folder on this phone, and Aperture started with a clean store so the app can open.")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your recovery phrase (if you saved it) is still the source of truth. If you have an iCloud wallet backup, restore it after you continue. Aperture does not invent a successful recovery — only you can restore from phrase or backup.")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasExportableBackup {
                Text("Export the quarantined files below and keep them with your recovery phrase if support ever needs them. Export does not restore balances by itself.")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text("Quarantined backup on this device")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.primary)
            if let quarantineURL {
                Text(verbatim: quarantineURL.lastPathComponent)
                    .font(UniTypography.caption2.monospaced())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .textSelection(.enabled)
            }
            UniButton(title: "Export quarantined files", variant: .secondary) {
                exportQuarantine()
            }
            if let exportError {
                Text(verbatim: exportError)
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.secondary)
            }
        }
        .padding(UniSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var ephemeralWarning: some View {
        Text("Creating or importing a wallet is blocked while storage is temporary. Free disk space, restart the device, or reinstall Aperture, then restore from your recovery phrase.")
            .font(UniTypography.body)
            .foregroundStyle(UniColors.Text.primary)
            .padding(UniSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UniColors.Card.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $isShowingTechnical) {
            Text(verbatim: incident?.reason ?? "No technical reason recorded.")
                .font(UniTypography.caption2.monospaced())
                .foregroundStyle(UniColors.Text.tertiary)
                .textSelection(.enabled)
                .padding(.top, UniSpacing.xs)
            Text(verbatim: "Store: \(incident?.storePath ?? AppDatabase.shared.storeURL.path)")
                .font(UniTypography.caption2.monospaced())
                .foregroundStyle(UniColors.Text.tertiary)
                .textSelection(.enabled)
        } label: {
            Text("Technical details")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: UniSpacing.s) {
            if isEphemeralStore {
                UniButton(title: "I understand — storage is temporary", variant: .primary) {
                    // User must still not create wallets; acknowledge clears
                    // only the one-shot panic if any, ephemeral writes stay off.
                    onAcknowledged()
                }
            } else {
                UniButton(title: "Start fresh on this device", variant: .primary) {
                    onAcknowledged()
                }
            }
            Text(isEphemeralStore
                 ? "Aperture will stay open but will refuse to save new wallets until permanent storage works again."
                 : "You will continue to onboarding with an empty wallet list. Export first if you have not already.")
                .font(UniTypography.caption2)
                .foregroundStyle(UniColors.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Export

    private func exportQuarantine() {
        exportError = nil
        guard let quarantineURL else {
            exportError = "No quarantined folder was found on this device."
            return
        }
        let files = DatabaseRecoveryIncident.exportableFiles(in: quarantineURL)
        guard !files.isEmpty else {
            exportError = "The quarantined folder is empty."
            return
        }
        // Copy into a fresh temp folder so the share sheet has stable URLs
        // the user can AirDrop / Save to Files without holding open DB locks.
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Aperture-CorruptStore-Export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
            var copied: [URL] = []
            for file in files {
                let dest = exportRoot.appendingPathComponent(file.lastPathComponent, isDirectory: false)
                try FileManager.default.copyItem(at: file, to: dest)
                copied.append(dest)
            }
            // Also drop a short README for non-technical recipients.
            let readme = exportRoot.appendingPathComponent("README.txt", isDirectory: false)
            let readmeBody = """
            Aperture quarantined wallet database export

            These files were moved aside because the live database failed an
            integrity or open check. They are not a guaranteed restore path.
            Keep your recovery phrase. Share this folder only with people you trust.

            Folder: \(quarantineURL.lastPathComponent)
            Reason: \(incident?.reason ?? "unknown")
            """
            try readmeBody.write(to: readme, atomically: true, encoding: .utf8)
            copied.append(readme)
            shareItems = copied
            isShowingShare = true
        } catch {
            exportError = "Could not prepare export: \(error.localizedDescription)"
        }
    }
}

// MARK: - Share sheet

private struct DatabaseRecoveryShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
