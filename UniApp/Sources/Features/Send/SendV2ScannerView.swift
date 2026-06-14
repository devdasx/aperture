import SwiftUI
@preconcurrency import AVFoundation
import PhotosUI
import CoreImage

/// **Send v2 · D2 — Scan QR.** Full-screen camera: dark surface, white
/// corner-bracket viewfinder, a green scan line, *"Point at a wallet QR
/// code"*. Chips: **Light** (torch toggle) and **From photos** (reads a QR
/// from an image). On lock-on, a white detection card slides up from the
/// bottom: green check, *"Address detected · Solana"* + truncated address +
/// **Use →**. EIP-681 / Solana Pay URIs are parsed for the address (the
/// amount/token parsing is the domain layer's job — T-062).
///
/// **Rule #3 (native-only):** reuses the project's `CameraPreviewUIView` /
/// `MetadataDelegate` (the same `AVCaptureSession` scanner the browser
/// uses), Core Image's `CIDetector` for the from-photos QR read, and
/// `PhotosPicker` for image selection. No third-party scanner.
///
/// **Rule #16:** the camera usage is honest (`NSCameraUsageDescription`).
/// Denied permission renders a calm "Camera access needed" surface.
struct SendV2ScannerView: View {
    let onDetected: (String) -> Void
    let onCancel: () -> Void

    @State private var permission: Permission = .pending
    @State private var torchOn: Bool = false
    @State private var detected: DetectedAddress?
    @State private var photoItem: PhotosPickerItem?
    @State private var detectTick: Int = 0

    @Environment(\.openURL) private var openURL

    enum Permission { case pending, granted, denied }

    var body: some View {
        ZStack {
            UniColors.Send.cameraBase.ignoresSafeArea()

            switch permission {
            case .pending:
                ProgressView().tint(UniColors.Text.onMedia)
            case .granted:
                cameraSurface
            case .denied:
                deniedSurface
            }

            // Top bar — close + title, over the camera.
            VStack {
                topBar
                Spacer()
            }

            // Detection card slides up on lock-on.
            if let detected {
                VStack {
                    Spacer()
                    detectionCard(detected)
                        .padding(.horizontal, UniSpacing.l)
                        .padding(.bottom, UniSpacing.xl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .task { await resolvePermission() }
        // `.impactLight` the moment the detection card slides up (handoff).
        .uniHaptic(.contextualImpact(.whisper), trigger: detectTick)
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await readQRFromPhoto(newItem) }
        }
    }

    // MARK: - Camera surface

    private var cameraSurface: some View {
        ZStack {
            SendV2CameraView(torchOn: torchOn) { payload in
                handlePayload(payload)
            }
            .ignoresSafeArea()

            // Dim scrim outside the viewfinder + the bracket reticle.
            viewfinder

            // Tools row.
            VStack {
                Spacer()
                if detected == nil {
                    instruction
                    toolsRow
                        .padding(.bottom, UniSpacing.xxl)
                }
            }
        }
    }

    private var viewfinder: some View {
        ZStack {
            ScannerBrackets()
                .stroke(UniColors.Text.onMedia, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 240, height: 240)
            ScanLine()
                .frame(width: 232, height: 240)
        }
        .accessibilityHidden(true)
    }

    private var instruction: some View {
        Text("Point at a wallet QR code")
            .font(UniTypography.subheadlineEmphasized)
            .foregroundStyle(UniColors.Text.onMedia)
            .padding(.bottom, UniSpacing.m)
    }

    private var toolsRow: some View {
        HStack(spacing: UniSpacing.m) {
            scannerChip(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill", title: "Light", isOn: torchOn) {
                torchOn.toggle()
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                ScannerChipLabel(systemName: "photo.on.rectangle", title: "From photos", isOn: false)
            }
        }
    }

    // MARK: - Detection card

    @ViewBuilder
    private func detectionCard(_ d: DetectedAddress) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(UniColors.Send.positive)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Address detected · \(d.network?.displayName ?? "Unknown")")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: SendDraft.shorten(d.address))
                    .font(UniTypography.caption1.monospaced())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer(minLength: 0)
            Button {
                onDetected(d.address)
            } label: {
                HStack(spacing: UniSpacing.xxs) {
                    Text("Use")
                    Image(systemName: "arrow.right")
                }
                .font(UniTypography.subheadlineEmphasized)
                .foregroundStyle(UniColors.Send.onDarkGlass)
                .padding(.horizontal, UniSpacing.m)
                .frame(height: 40)
                .background(Capsule().fill(UniColors.Send.darkGlass))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // `.select` on Use → (handoff).
            .uniHaptic(.selection, trigger: d.address)
            .accessibilityLabel(Text("Use this address"))
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                .fill(UniColors.Material.card)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(UniColors.Text.onMedia)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(UniColors.Send.cameraScrimLight))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close scanner"))
            Spacer()
            Text("Scan")
                .font(UniTypography.headline)
                .foregroundStyle(UniColors.Text.onMedia)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.top, UniSpacing.s)
    }

    // MARK: - Denied

    private var deniedSurface: some View {
        VStack(spacing: UniSpacing.l) {
            Image(systemName: "video.slash")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(UniColors.Text.onMedia.opacity(0.7))
            Text("Camera access needed")
                .font(UniTypography.headline)
                .foregroundStyle(UniColors.Text.onMedia)
            Text("Aperture uses the camera to scan a recipient's wallet QR code. Enable camera access in Settings, or pick a QR image from your photos.")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.onMedia.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, UniSpacing.l)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(UniTypography.buttonLabel)
            .foregroundStyle(UniColors.Text.onMedia)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("Pick from photos")
                    .font(UniTypography.buttonLabel)
                    .foregroundStyle(UniColors.Text.onMedia.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, UniSpacing.l)
    }

    // MARK: - Chips

    @ViewBuilder
    private func scannerChip(systemName: String, title: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ScannerChipLabel(systemName: systemName, title: title, isOn: isOn)
        }
        .buttonStyle(.plain)
        // `.toggle` on torch state change (handoff).
        .uniHaptic(.toggle, trigger: isOn)
    }

    // MARK: - Payload handling

    private func handlePayload(_ payload: String) {
        guard detected == nil else { return }
        let parsed = SendURIParser.parse(payload)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            detected = DetectedAddress(address: parsed.address, network: parsed.network)
        }
        detectTick += 1
    }

    private func readQRFromPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let ciImage = CIImage(image: uiImage) else { return }
        let context = CIContext()
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: context, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ciImage) ?? []
        for case let qr as CIQRCodeFeature in features {
            if let message = qr.messageString, !message.isEmpty {
                handlePayload(message)
                return
            }
        }
    }

    // MARK: - Permission

    private func resolvePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: permission = .granted
        case .denied, .restricted: permission = .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
        @unknown default: permission = .denied
        }
    }

    struct DetectedAddress: Equatable {
        let address: String
        let network: SupportedChain?
    }
}

// MARK: - Scanner chip label (shared by the torch chip + the PhotosPicker)

/// The pill label used by both the Light torch chip and the From-photos
/// `PhotosPicker`. A standalone `View` (not a method) so the `PhotosPicker`
/// trailing closure — which is nonisolated — can build it without crossing
/// the MainActor boundary.
private struct ScannerChipLabel: View {
    let systemName: String
    let title: LocalizedStringKey
    let isOn: Bool

    var body: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
            Text(title)
                .font(UniTypography.subheadlineEmphasized)
        }
        .foregroundStyle(isOn ? UniColors.Text.inverted : UniColors.Text.onMedia)
        .padding(.horizontal, UniSpacing.m)
        .frame(height: 44)
        .background(Capsule().fill(isOn ? UniColors.Text.onMedia : UniColors.Send.cameraScrim))
        .contentShape(Capsule())
    }
}

// MARK: - Camera view (torch-aware wrapper over the shared CameraPreviewUIView)

/// Wraps the project's `CameraPreviewUIView` (Rule #3 — reuse the browser's
/// `AVCaptureSession` scanner) and threads a `torchOn` binding so the
/// Light chip toggles the device torch.
private struct SendV2CameraView: UIViewRepresentable {
    let torchOn: Bool
    let onDecode: (String) -> Void

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.start(onDecode: onDecode)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.setTorch(torchOn)
    }

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: ()) {
        uiView.setTorch(false)
        uiView.stop()
    }
}

// MARK: - Viewfinder shapes (structural, not icons — Rule #7 exception)

/// White corner brackets around the viewfinder (structural layout, not an
/// icon — it frames where to point, it doesn't carry symbol meaning).
private struct ScannerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let len = rect.width * 0.22
        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        // Top-right
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return path
    }
}

/// The animated green scan line that sweeps the viewfinder (structural
/// motion, not an icon).
private struct ScanLine: View {
    @State private var offset: CGFloat = -0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [UniColors.Send.positive.opacity(0), UniColors.Send.positive, UniColors.Send.positive.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .offset(y: offset * proxy.size.height)
                .onAppear {
                    guard !reduceMotion else { offset = 0; return }
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        offset = 0.5
                    }
                }
        }
    }
}

// MARK: - URI parser (EIP-681 / Solana Pay aware)

/// Parses a scanned/pasted payload into an address + best-guess network.
/// Handles plain addresses, `ethereum:` (EIP-681), and `solana:` (Solana
/// Pay) URIs. The amount / token parameters are the domain layer's job
/// (T-062); this design layer extracts the address + network only.
enum SendURIParser {
    struct Result { let address: String; let network: SupportedChain? }

    static func parse(_ payload: String) -> Result {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // EIP-681: ethereum:0xADDR@chainId?... — take the address segment.
        if trimmed.lowercased().hasPrefix("ethereum:") {
            let body = String(trimmed.dropFirst("ethereum:".count))
            let addr = body.split(whereSeparator: { $0 == "@" || $0 == "?" }).first.map(String.init) ?? body
            return Result(address: addr, network: .ethereum)
        }
        // Solana Pay: solana:ADDR?... — take the address segment.
        if trimmed.lowercased().hasPrefix("solana:") {
            let body = String(trimmed.dropFirst("solana:".count))
            let addr = body.split(separator: "?").first.map(String.init) ?? body
            return Result(address: addr, network: .solana)
        }
        // bitcoin: BIP-21
        if trimmed.lowercased().hasPrefix("bitcoin:") {
            let body = String(trimmed.dropFirst("bitcoin:".count))
            let addr = body.split(separator: "?").first.map(String.init) ?? body
            return Result(address: addr, network: .bitcoin)
        }
        // Plain address — guess network by shape.
        let network: SupportedChain? = {
            if trimmed.hasPrefix("0x"), trimmed.count == 42 { return .ethereum }
            if trimmed.hasPrefix("bc1") || trimmed.hasPrefix("1") || trimmed.hasPrefix("3") { return .bitcoin }
            if trimmed.count >= 32 && trimmed.count <= 44 { return .solana }
            return nil
        }()
        return Result(address: trimmed, network: network)
    }
}
