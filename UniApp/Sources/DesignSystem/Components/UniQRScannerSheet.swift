import SwiftUI
import PhotosUI
import Vision
import UniformTypeIdentifiers
// `@preconcurrency` — AVFoundation's capture types predate Sendable
// annotation; `AVCaptureSession.start/stopRunning` are documented
// thread-safe and must run off-main (they block). This is the
// compiler-sanctioned bridge until Apple annotates the framework.
@preconcurrency import AVFoundation

/// **Aperture Scanner** — the single, unified, full-screen camera scanner for
/// every QR surface in the app (2026-06-20 rebuild, `design_handoff_scanner`).
/// A full-bleed dark viewfinder with a corner-bracket reticle + scan beam that
/// auto-detects what it sees and acts:
///
/// - **Wallet address** (every supported chain — EVM `0x…`, Bitcoin family,
///   Solana, XRP, TON, TRON, Aptos, Sui, Stellar, NEAR, Polkadot…): the reticle
///   locks to a green ring and a glass sheet rises with the chain icon, the
///   address, and **Copy / Send**.
/// - **WalletConnect** (`wc:` URI): a blue ring + **Cancel / Connect**.
/// - **Unrecognized**: a red ring + **Paste / Try again**.
///
/// **Three real ways in (Rule #3 — all native):** live camera (AVFoundation),
/// a photo from the library (PhotosUI + Vision), and the clipboard. Gallery +
/// Paste work even when the camera is denied.
///
/// **Two modes.** With `onRawDeliver` set (the Send-recipient scan, which is
/// already scoped to a chain), the scanner just hands back the raw payload and
/// closes — no result sheet. Otherwise it runs the full auto-detect + result
/// flow above. The name `UniQRScannerSheet` is kept so existing call sites
/// migrate by adding the new closures; the surface is now full-screen.
struct UniQRScannerSheet: View {
    /// Inline title (default "Scan").
    var title: LocalizedStringKey = "Scan"
    /// Hint under the reticle while scanning.
    var prompt: LocalizedStringKey = "Scan any QR code · Wallet address or WalletConnect"
    /// **Raw-deliver mode.** When set, ANY decoded payload (camera / gallery /
    /// paste) is handed straight back and the scanner closes — no
    /// classification, no result sheet. Used by the Send recipient field, which
    /// validates downstream against its already-chosen chain.
    var onRawDeliver: ((String) -> Void)? = nil
    /// Standalone WalletConnect connect (Browser / global scan).
    var onConnect: ((String) -> Void)? = nil
    /// Standalone "Send to this address" — opens the send flow pre-filled. When
    /// nil the address sheet shows only Copy.
    var onSend: ((SupportedChain, String) -> Void)? = nil
    /// Backwards-compatible alias for `onRawDeliver` (older `onScan:` callers).
    var onScan: ((String) -> Void)? = nil

    @State private var permissionState: PermissionState = .pending
    @State private var detection: ScannerDetection?
    @State private var hasDelivered: Bool = false
    @State private var isTorchOn: Bool = false
    @State private var cameraView: CameraPreviewUIView?
    @State private var photoItem: PhotosPickerItem?
    @State private var note: LocalizedStringKey?
    @State private var copied: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum PermissionState { case pending, granted, denied }

    /// The single raw-deliver handler (new `onRawDeliver` or legacy `onScan`).
    private var rawDeliverHandler: ((String) -> Void)? { onRawDeliver ?? onScan }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch permissionState {
            case .pending: waitingSurface
            case .granted: grantedSurface
            case .denied:  deniedSurface
            }

            topBar
        }
        .preferredColorScheme(.dark)
        .task { await resolvePermission() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await decodePickedPhoto(item) }
        }
    }

    // MARK: - Top bar (close · title · torch)

    private var topBar: some View {
        VStack {
            HStack {
                circleControl(systemImage: "xmark") {
                    UniHapticEngine.shared.play(.contextualImpact(.tap))
                    dismiss()
                }
                Spacer()
                Text(title)
                    .font(UniTypography.body.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if permissionState == .granted, cameraView?.isTorchAvailable ?? false {
                    circleControl(systemImage: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill", filled: isTorchOn) {
                        toggleTorch()
                    }
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            Spacer()
        }
    }

    private func circleControl(systemImage: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: .circle)
                .background(filled ? Color.white : Color.clear, in: .circle)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permission surfaces

    private var waitingSurface: some View {
        VStack(spacing: UniSpacing.m) {
            ProgressView().tint(.white)
            Text("Requesting camera access…")
                .font(UniTypography.body)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var deniedSurface: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
            Text("Camera access needed")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text("Turn on camera access in Settings to scan. You can still pick a QR from your photos or paste one.")
                .font(UniTypography.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UniSpacing.xl)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Enable camera")
                    .font(UniTypography.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, UniSpacing.l)
            Spacer()
            actionBar(showsTorch: false)
                .padding(.bottom, UniSpacing.l)
        }
    }

    // MARK: - Granted (live camera + reticle + result)

    private var grantedSurface: some View {
        ZStack {
            QRScannerCameraView(onDecode: handleDecode(_:), onReady: { cameraView = $0 })
                .ignoresSafeArea()

            ScannerReticle(status: detection.map(ringStatus), reduceMotion: reduceMotion)
                .allowsHitTesting(false)

            VStack(spacing: UniSpacing.l) {
                Spacer()
                if detection == nil {
                    Text(prompt)
                        .font(UniTypography.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, UniSpacing.xl)
                    noteLine
                    actionBar(showsTorch: true)
                        .padding(.bottom, UniSpacing.l)
                }
            }

            if let detection {
                resultSheet(for: detection)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82), value: detection)
    }

    /// Map a detection to the reticle ring color.
    private func ringStatus(_ d: ScannerDetection) -> ScannerReticle.Status {
        switch d {
        case .address:       return .ok
        case .walletConnect: return .walletConnect
        case .unrecognized:  return .error
        }
    }

    // MARK: - Result sheet

    @ViewBuilder
    private func resultSheet(for detection: ScannerDetection) -> some View {
        VStack {
            Spacer()
            VStack(spacing: UniSpacing.m) {
                switch detection {
                case .address(let chain, let value):
                    addressResult(chain: chain, value: value)
                case .walletConnect(let uri):
                    walletConnectResult(uri: uri)
                case .unrecognized:
                    unrecognizedResult
                }
            }
            .padding(UniSpacing.l)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.horizontal, UniSpacing.m)
            .padding(.bottom, UniSpacing.l)
        }
    }

    @ViewBuilder
    private func addressResult(chain: SupportedChain, value: String) -> some View {
        HStack(spacing: UniSpacing.s) {
            chainIcon(chain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: chain.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 0.50))
                }
                Text(verbatim: truncatedMiddle(value))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: UniSpacing.s) {
            pillButton(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc", dark: false) {
                copyAddress(value)
            }
            if let onSend {
                pillButton("Send", systemImage: "arrow.up.right", dark: true) {
                    UniHapticEngine.shared.play(.success)
                    onSend(chain, value)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func walletConnectResult(uri: String) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color(red: 0.23, green: 0.55, blue: 0.96))
            VStack(alignment: .leading, spacing: 2) {
                Text("WalletConnect")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("Connect this dApp to your wallet.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: UniSpacing.s) {
            pillButton("Cancel", systemImage: nil, dark: false) { resumeScanning() }
            pillButton("Connect", systemImage: "bolt.fill", dark: true, tint: Color(red: 0.23, green: 0.55, blue: 0.96)) {
                UniHapticEngine.shared.play(.success)
                onConnect?(uri)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var unrecognizedResult: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color(red: 1.0, green: 0.36, blue: 0.32))
            VStack(alignment: .leading, spacing: 2) {
                Text("Code not recognized")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("That isn't a wallet address or a WalletConnect code.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: UniSpacing.s) {
            pillButton("Paste", systemImage: "doc.on.clipboard", dark: false) {
                resumeScanning(); pasteFromClipboard()
            }
            pillButton("Try again", systemImage: "arrow.clockwise", dark: true) { resumeScanning() }
        }
    }

    private func chainIcon(_ chain: SupportedChain) -> some View {
        Group {
            if let asset = chain.logoAssetName {
                Image(asset).resizable().scaledToFit()
            } else {
                Circle().fill(.white.opacity(0.12))
                    .overlay(Text(verbatim: String(chain.displayName.prefix(1))).font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func pillButton(_ title: LocalizedStringKey, systemImage: String?, dark: Bool, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(dark ? .white : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(dark ? tint.opacity(tint == .white ? 1 : 1) : Color.white.opacity(0.12), in: Capsule())
            .foregroundStyle(dark && tint == .white ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transient note

    @ViewBuilder
    private var noteLine: some View {
        if let note {
            Text(note)
                .font(UniTypography.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, UniSpacing.xl)
                .transition(.opacity)
        }
    }

    // MARK: - Action bar (Gallery / Paste)

    @ViewBuilder
    private func actionBar(showsTorch: Bool) -> some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            HStack(spacing: UniSpacing.s) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    ActionBarLabel(title: "Gallery", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.glass)

                Button { pasteFromClipboard() } label: {
                    ActionBarLabel(title: "Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, UniSpacing.xl)
    }

    // MARK: - Decode / classify / deliver

    private func handleDecode(_ payload: String) {
        guard !hasDelivered, detection == nil else { return }
        if let rawDeliverHandler {
            hasDelivered = true
            UniHapticEngine.shared.play(.selection)
            rawDeliverHandler(payload)
            return
        }
        classifyAndPresent(payload)
    }

    private func classifyAndPresent(_ payload: String) {
        let result = ScannerClassifier.classify(payload)
        UniHapticEngine.shared.play(.selection)
        switch result {
        case .address, .walletConnect:
            UniHapticEngine.shared.play(.success)
        case .unrecognized:
            UniHapticEngine.shared.play(.error)
        }
        detection = result
    }

    private func resumeScanning() {
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        copied = false
        detection = nil
        hasDelivered = false
        clearNote()
    }

    // MARK: - Gallery (PhotosUI + Vision)

    private func decodePickedPhoto(_ item: PhotosPickerItem) async {
        clearNote()
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            setNote("Couldn't open that photo."); photoItem = nil; return
        }
        let payloads = await Self.decodeQRPayloads(in: cgImage)
        photoItem = nil
        guard let first = payloads.first else { setNote("No QR code found in that image."); return }
        UniHapticEngine.shared.play(.contextualImpact(.commit))
        handleDecode(first)
    }

    nonisolated private static func decodeQRPayloads(in cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    let results = (request.results ?? [])
                        .compactMap { $0.payloadStringValue }
                        .filter { !$0.isEmpty }
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // MARK: - Paste / Torch / Copy

    private func pasteFromClipboard() {
        clearNote()
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.isEmpty else { setNote("Nothing to paste."); return }
        UniHapticEngine.shared.play(.contextualImpact(.commit))
        handleDecode(pasted)
    }

    private func toggleTorch() {
        UniHapticEngine.shared.play(.toggle)
        isTorchOn.toggle()
        cameraView?.setTorch(isTorchOn)
    }

    private func copyAddress(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        UniHapticEngine.shared.play(.success)
        withAnimation(.easeOut(duration: 0.2)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeIn(duration: 0.25)) { copied = false }
        }
    }

    // MARK: - Helpers

    private func setNote(_ value: LocalizedStringKey) {
        withAnimation(.easeOut(duration: 0.2)) { note = value }
    }
    private func clearNote() {
        if note != nil { withAnimation(.easeOut(duration: 0.2)) { note = nil } }
    }

    private func truncatedMiddle(_ s: String) -> String {
        guard s.count > 18 else { return s }
        return "\(s.prefix(10))…\(s.suffix(6))"
    }

    private func resolvePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: permissionState = .granted
        case .denied, .restricted: permissionState = .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { UniHapticEngine.shared.play(.success) }
            permissionState = granted ? .granted : .denied
        @unknown default: permissionState = .denied
        }
    }
}

// MARK: - Classification

/// What a scanned payload turned out to be.
enum ScannerDetection: Equatable {
    case address(chain: SupportedChain, value: String)
    case walletConnect(uri: String)
    case unrecognized
}

/// Classifies a raw scanned payload across every supported chain + WalletConnect.
/// Uses Trust Wallet Core's real per-chain address validation (no regex guess).
enum ScannerClassifier {
    static func classify(_ raw: String) -> ScannerDetection {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognized }
        if trimmed.lowercased().hasPrefix("wc:") { return .walletConnect(uri: trimmed) }

        let address = strippedAddress(from: trimmed)
        guard !address.isEmpty else { return .unrecognized }

        let service = WalletCoreKeyImportService()
        // EVM chains all validate the same 0x address; iterating in
        // `SupportedChain.allCases` order returns a representative chain (the
        // user re-confirms the network in the send flow). Non-EVM addresses
        // match exactly one chain by construction.
        for chain in SupportedChain.allCases where service.validateAddress(address, on: chain) {
            return .address(chain: chain, value: address)
        }
        return .unrecognized
    }

    /// Strip a payment-URI scheme + query so the bare address can be validated:
    /// EIP-681 `ethereum:0x…@1?value=…`, BIP-21 `bitcoin:bc1…?amount=…`, Solana
    /// Pay `solana:…`, etc. A plain address passes through unchanged.
    private static func strippedAddress(from input: String) -> String {
        var s = input
        if let colon = s.firstIndex(of: ":") {
            let scheme = s[..<colon].lowercased()
            let schemes: Set<String> = [
                "ethereum", "bitcoin", "litecoin", "dogecoin", "bitcoincash",
                "solana", "ripple", "xrp", "ton", "tron", "aptos", "sui",
                "stellar", "near", "polkadot"
            ]
            if schemes.contains(scheme) {
                s = String(s[s.index(after: colon)...])
            }
        }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }       // BIP-21 / EIP-681 query
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }     // EIP-681 chain suffix
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Action-bar label

nonisolated private struct ActionBarLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: UniSpacing.xxs) {
            Image(systemName: systemImage).font(.system(size: 20, weight: .regular))
            Text(title).font(UniTypography.caption1.weight(.medium))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .contentShape(Capsule())
    }
}

// MARK: - Scanner reticle (corner brackets → full status ring + scan beam)

/// The reticle: a centered square cutout in a dimmed scrim. While scanning it
/// shows four white corner brackets and an animated scan beam; on a detection
/// the brackets give way to a single full rounded ring in the status color
/// (green OK · blue WalletConnect · red error), per the handoff.
private struct ScannerReticle: View {
    enum Status { case ok, walletConnect, error
        var color: Color {
            switch self {
            case .ok:            return Color(red: 0.18, green: 0.82, blue: 0.50)
            case .walletConnect: return Color(red: 0.23, green: 0.55, blue: 0.96)
            case .error:         return Color(red: 1.0, green: 0.36, blue: 0.32)
            }
        }
    }
    let status: Status?
    let reduceMotion: Bool

    private let sideFraction: CGFloat = 0.66
    private let bracketLength: CGFloat = 30
    private let bracketWidth: CGFloat = 4
    private let radius: CGFloat = 34

    @State private var beam: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * sideFraction
            let rect = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2, width: side, height: side)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                if let status {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .inset(by: 2)
                        .stroke(status.color, lineWidth: bracketWidth)
                        .frame(width: side, height: side)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: status.color.opacity(0.6), radius: 12)
                } else {
                    cornerBrackets(in: rect)
                    if !reduceMotion { scanBeam(in: rect) }
                }
            }
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { beam = 1 }
            }
        }
    }

    private func scanBeam(in rect: CGRect) -> some View {
        let y = rect.minY + 8 + (rect.height - 16) * beam
        return LinearGradient(
            colors: [.clear, Color.white.opacity(0.0), Color.white.opacity(0.85), Color.white.opacity(0.0)],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: rect.width - 16, height: 2)
        .overlay(Rectangle().fill(Color.white.opacity(0.9)).frame(height: 1.5))
        .position(x: rect.midX, y: y)
        .mask(RoundedRectangle(cornerRadius: radius, style: .continuous).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY))
    }

    @ViewBuilder
    private func cornerBrackets(in rect: CGRect) -> some View {
        let r = radius
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + bracketLength))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + bracketLength, y: rect.minY))
            path.move(to: CGPoint(x: rect.maxX - bracketLength, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bracketLength))
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - bracketLength))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - bracketLength, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX + bracketLength, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bracketLength))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: bracketWidth, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - QRScannerCameraView (AVCaptureSession wrapper)

/// `UIViewRepresentable` wrapping an `AVCaptureSession` with an
/// `AVCaptureMetadataOutput` configured for `qr` codes. Streams decoded
/// payloads to `onDecode`; `onReady` hands the parent the live view so the
/// torch control can reach `setTorch(_:)`. Pure system code (Rule #3).
struct QRScannerCameraView: UIViewRepresentable {
    let onDecode: (String) -> Void
    var onReady: (CameraPreviewUIView) -> Void = { _ in }

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.start(onDecode: onDecode)
        DispatchQueue.main.async { onReady(view) }
        return view
    }
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: ()) { uiView.stop() }
}

/// UIView hosting the camera preview layer + the `AVCaptureSession`.
final class CameraPreviewUIView: UIView {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var onDecode: ((String) -> Void)?
    private let delegate = MetadataDelegate()
    private var captureDevice: AVCaptureDevice?

    var isTorchAvailable: Bool {
        guard let device = captureDevice else { return false }
        return device.hasTorch && device.isTorchAvailable
    }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    func setTorch(_ on: Bool) {
        guard let device = captureDevice, device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch { /* transient lock failure — chip just doesn't toggle */ }
    }

    func start(onDecode: @escaping (String) -> Void) {
        self.onDecode = onDecode
        delegate.onDecode = onDecode
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.captureDevice = device
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        }
        let layer = (self.layer as? AVCaptureVideoPreviewLayer) ?? AVCaptureVideoPreviewLayer(session: session)
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer
        let sessionRef = session
        DispatchQueue.global(qos: .userInitiated).async { sessionRef.startRunning() }
    }

    func stop() {
        let sessionRef = session
        DispatchQueue.global(qos: .userInitiated).async { sessionRef.stopRunning() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

/// Picks the first non-empty payload and hands it to the closure.
final class MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onDecode: ((String) -> Void)?
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let payload = readable.stringValue, !payload.isEmpty else { continue }
            onDecode?(payload)
            return
        }
    }
}
