import SwiftUI
import PhotosUI
import Vision
// `@preconcurrency` — AVFoundation's capture types predate Sendable
// annotation; `AVCaptureSession.start/stopRunning` are documented
// thread-safe and must run off-main (they block). This is the
// compiler-sanctioned bridge until Apple annotates the framework.
@preconcurrency import AVFoundation

/// The single, unified QR scanner for every QR surface in Aperture —
/// WalletConnect pairing in the dApp browser, the Send recipient address
/// scan, and any future surface that needs to read a QR.
///
/// **One component, configurable purpose.** Rather than per-caller scanner
/// sheets (the prior `BrowserQRScanSheet` hard-coded the WalletConnect
/// title AND a `wc:`-only filter — which silently broke the Send recipient
/// scan, since an address QR never matched `wc:` and never delivered), this
/// component takes:
/// - `title` — the inline nav-bar title.
/// - `prompt` — the instructional line beneath the reticle.
/// - `accepts` — a predicate the decoded payload must pass before delivery
///   (default: accept anything). Browser passes `{ $0.hasPrefix("wc:") }`;
///   Send accepts anything and validates downstream.
/// - `onScan` — fired once, with the first payload that passes `accepts`.
///
/// **Three ways in (Rule #3 — all native).** Live camera (AVFoundation),
/// a photo from the library (PhotosUI `PhotosPicker` + Vision QR decode),
/// and the clipboard (`UIPasteboard`). Gallery + Paste work even when the
/// camera permission is denied — a user can pick a QR from Photos without
/// granting the camera — so the denied surface still offers them.
///
/// **Layers (Rule #2 §B.3).** Content layer: the live camera feed +
/// the reticle + the prompt, opaque over `Send.cameraBase`. Functional
/// layer (Liquid Glass via system APIs only): the nav bar and the bottom
/// action bar (`GlassEffectContainer` of `.buttonStyle(.glass)` controls).
/// Two glass layers max; no glass on long-form content.
///
/// **Honesty (Rule #16).** Each control says plainly what it does — "From
/// photos", "Paste", "Light" — and the camera-usage string in
/// `INFOPLIST_KEY_NSCameraUsageDescription` states the real purpose. No
/// overclaim.
struct UniQRScannerSheet: View {
    var title: LocalizedStringKey
    var prompt: LocalizedStringKey
    /// Predicate the decoded payload must pass before being delivered.
    /// Default accepts anything; callers narrow it (e.g. the browser to
    /// `wc:` URIs). Validation of the *content* still lives downstream —
    /// `accepts` is a routing gate, not a full validator.
    var accepts: (String) -> Bool = { _ in true }
    let onScan: (String) -> Void

    @State private var permissionState: PermissionState = .pending
    @State private var hasDelivered: Bool = false
    @State private var isTorchOn: Bool = false
    /// The live camera view, retained so the torch control can reach its
    /// `setTorch(_:)` after the session is running.
    @State private var cameraView: CameraPreviewUIView?
    @State private var photoItem: PhotosPickerItem?
    /// Calm, transient note shown above the action bar when a non-camera
    /// path can't produce a usable code ("No QR code found in that image",
    /// "Nothing to paste", "That's not a valid code"). Cleared on the next
    /// successful path or when the user taps a control again.
    @State private var note: LocalizedStringKey?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum PermissionState {
        case pending
        case granted
        case denied
    }

    var body: some View {
        NavigationStack {
            ZStack {
                UniColors.Send.cameraBase
                    .ignoresSafeArea()

                switch permissionState {
                case .pending:
                    waitingSurface
                case .granted:
                    grantedSurface
                case .denied:
                    deniedSurface
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The nav bar floats over a guaranteed-dark camera feed —
            // force its content to read light so Cancel + the title stay
            // legible regardless of the user's appearance.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await resolvePermission() }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await decodePickedPhoto(item) }
            }
        }
    }

    // MARK: - Permission states

    @ViewBuilder
    private var waitingSurface: some View {
        VStack(spacing: UniSpacing.m) {
            ProgressView()
                .tint(UniColors.Text.onMedia)
            UniBody(
                text: "Requesting camera access…",
                alignment: .center,
                color: UniColors.Text.onMedia
            )
        }
    }

    /// Camera granted: the live feed + the reticle + the prompt, with the
    /// full action bar (Gallery / Paste / Light) at the bottom.
    @ViewBuilder
    private var grantedSurface: some View {
        ZStack {
            QRScannerCameraView(
                onDecode: deliver(_:),
                onReady: { cameraView = $0 }
            )
            .ignoresSafeArea()

            QRReticle()
                .allowsHitTesting(false)

            VStack(spacing: UniSpacing.l) {
                Spacer()
                UniBody(
                    text: prompt,
                    alignment: .center,
                    color: UniColors.Text.onMedia
                )
                .padding(.horizontal, UniSpacing.xl)
                noteLine
                actionBar(showsTorch: true)
                    .padding(.bottom, UniSpacing.l)
            }
        }
    }

    /// Camera denied: the calm "open Settings" surface — but Gallery + Paste
    /// still work (no camera needed to read a QR from Photos / clipboard),
    /// so the action bar stays present, minus the torch.
    @ViewBuilder
    private var deniedSurface: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(UniColors.Send.cameraOnMediaDimIcon)
                .accessibilityHidden(true)

            UniHeadline(text: "Camera access needed", alignment: .center)
                .foregroundStyle(UniColors.Text.onMedia)

            UniBody(
                text: "Turn on camera access in Settings to scan with the camera. You can still pick a QR code from your photos or paste one.",
                alignment: .center,
                color: UniColors.Send.cameraOnMediaDimBody
            )
            .padding(.horizontal, UniSpacing.xl)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("Open Settings")
                    .font(UniTypography.body.weight(.semibold))
                    .foregroundStyle(UniColors.Text.onMedia)
                    .padding(.horizontal, UniSpacing.m)
                    .frame(height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.glass)

            Spacer()

            noteLine
            actionBar(showsTorch: false)
                .padding(.bottom, UniSpacing.l)
        }
    }

    // MARK: - Transient note

    @ViewBuilder
    private var noteLine: some View {
        if let note {
            UniFootnote(text: note, alignment: .center, color: UniColors.Send.cameraOnMediaNote)
                .padding(.horizontal, UniSpacing.xl)
                .transition(.opacity)
        }
    }

    // MARK: - Action bar (Liquid Glass functional layer)

    /// Gallery / Paste / Light, grouped in a `GlassEffectContainer` so the
    /// system morphs them as a set — the canonical home for
    /// `.buttonStyle(.glass)` (chrome, not content). The torch is hidden
    /// when there's no camera (denied surface) or no torch (simulator,
    /// front camera).
    @ViewBuilder
    private func actionBar(showsTorch: Bool) -> some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            HStack(spacing: UniSpacing.s) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    ActionBarLabel(title: "From photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.glass)

                Button {
                    pasteFromClipboard()
                } label: {
                    ActionBarLabel(title: "Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.glass)

                if showsTorch && (cameraView?.isTorchAvailable ?? false) {
                    Button {
                        toggleTorch()
                    } label: {
                        ActionBarLabel(
                            title: isTorchOn ? "Light on" : "Light",
                            systemImage: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill"
                        )
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(.horizontal, UniSpacing.l)
    }

    // MARK: - Delivery

    /// Route a decoded payload: deliver the first one that passes `accepts`,
    /// otherwise ignore it (the camera keeps scanning; a non-camera path
    /// shows a calm note instead).
    private func deliver(_ decoded: String) {
        guard !hasDelivered else { return }
        guard accepts(decoded) else { return }
        hasDelivered = true
        onScan(decoded)
    }

    /// Same gate as `deliver`, but for the explicit one-shot paths (gallery
    /// / paste). Returns whether the payload was accepted so the caller can
    /// surface a note when it wasn't.
    @discardableResult
    private func tryDeliver(_ decoded: String, rejectNote: LocalizedStringKey) -> Bool {
        guard accepts(decoded) else {
            setNote(rejectNote)
            return false
        }
        guard !hasDelivered else { return false }
        hasDelivered = true
        onScan(decoded)
        return true
    }

    // MARK: - Gallery (PhotosUI + Vision)

    /// Load the picked image and decode a QR from it with Vision — fully
    /// native (Rule #3): `VNDetectBarcodesRequest` constrained to `.qr`,
    /// run through a `VNImageRequestHandler(cgImage:)`. The first QR
    /// payload that passes `accepts` is delivered; otherwise a calm note.
    private func decodePickedPhoto(_ item: PhotosPickerItem) async {
        clearNote()
        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let uiImage = UIImage(data: data),
            let cgImage = uiImage.cgImage
        else {
            setNote("Couldn't open that photo.")
            photoItem = nil
            return
        }

        let payloads = await Self.decodeQRPayloads(in: cgImage)
        photoItem = nil

        guard !payloads.isEmpty else {
            setNote("No QR code found in that image.")
            return
        }
        if let match = payloads.first(where: accepts) {
            _ = tryDeliver(match, rejectNote: "That's not a valid code.")
        } else {
            // A QR was found but none matched the caller's filter.
            setNote("That's not the right kind of QR code.")
        }
    }

    /// Off-main Vision decode. Returns every QR payload found in the image,
    /// in detection order. Static + `nonisolated` so it runs off the main
    /// actor (Rule #28) — Vision's request handler is synchronous and can
    /// be slow on large photos.
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

    // MARK: - Paste

    private func pasteFromClipboard() {
        clearNote()
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.isEmpty else {
            setNote("Nothing to paste.")
            return
        }
        _ = tryDeliver(pasted, rejectNote: "That's not a valid code.")
    }

    // MARK: - Torch

    private func toggleTorch() {
        clearNote()
        isTorchOn.toggle()
        cameraView?.setTorch(isTorchOn)
    }

    // MARK: - Note helpers

    private func setNote(_ value: LocalizedStringKey) {
        withAnimation(.easeOut(duration: 0.2)) { note = value }
    }

    private func clearNote() {
        if note != nil {
            withAnimation(.easeOut(duration: 0.2)) { note = nil }
        }
    }

    // MARK: - Permission

    private func resolvePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permissionState = .granted
        case .denied, .restricted:
            permissionState = .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
        @unknown default:
            permissionState = .denied
        }
    }
}

// MARK: - Action-bar label

/// One action-bar control's label — icon over a short verb, sized for a
/// comfortable thumb target. Hit-tests the painted glass capsule, not the
/// label's intrinsic bounds (Rule #19 §D hit-test invariant). Extracted to
/// its own view so it can sit inside `PhotosPicker` / `Button` label
/// closures (nonisolated `@ViewBuilder` contexts) without a main-actor
/// isolation crossing.
private struct ActionBarLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: UniSpacing.xxs) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
            Text(title)
                .font(UniTypography.caption1.weight(.medium))
        }
        .foregroundStyle(UniColors.Text.onMedia)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .contentShape(Capsule())
    }
}

// MARK: - QR reticle (corner-bracket frame over a dimmed surround)

/// A modern scan reticle: a centered square cutout in a dimmed scrim, with
/// four rounded corner brackets marking the capture region. This replaces
/// the prior giant ultraLight `viewfinder` glyph — it reads as "aim here"
/// without a heavy symbol dominating the feed. Structural shapes only
/// (Rule #7 §C: these carry layout, not meaning), tokenized colors only
/// (Rule #4).
private struct QRReticle: View {
    /// The capture window's side as a fraction of the smaller screen edge.
    private let sideFraction: CGFloat = 0.66
    /// How far each corner bracket runs along its two edges.
    private let bracketLength: CGFloat = 28
    private let bracketWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * sideFraction
            let rect = CGRect(
                x: (geo.size.width - side) / 2,
                y: (geo.size.height - side) / 2,
                width: side,
                height: side
            )
            ZStack {
                // Dim everything OUTSIDE the capture window via an
                // even-odd punched scrim.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRoundedRect(
                        in: rect,
                        cornerSize: CGSize(width: UniRadius.hero, height: UniRadius.hero)
                    )
                }
                .fill(UniColors.Send.cameraScrim, style: FillStyle(eoFill: true))

                cornerBrackets(in: rect)
            }
            .accessibilityHidden(true)
        }
    }

    /// Four rounded corner brackets hugging the capture window.
    @ViewBuilder
    private func cornerBrackets(in rect: CGRect) -> some View {
        let r = UniRadius.hero
        Path { path in
            // Top-left
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + bracketLength))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + r, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.minX + bracketLength, y: rect.minY))
            // Top-right
            path.move(to: CGPoint(x: rect.maxX - bracketLength, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + r),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bracketLength))
            // Bottom-right
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - bracketLength))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - bracketLength, y: rect.maxY))
            // Bottom-left
            path.move(to: CGPoint(x: rect.minX + bracketLength, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bracketLength))
        }
        .stroke(
            UniColors.Text.onMedia,
            style: StrokeStyle(lineWidth: bracketWidth, lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - QRScannerCameraView (AVCaptureSession wrapper)

/// `UIViewRepresentable` wrapping an `AVCaptureSession` with an
/// `AVCaptureMetadataOutput` configured for `qr` codes. Streams every
/// decoded payload to `onDecode`; the parent gates them through `accepts`
/// and delivers the first match. `onReady` hands the parent the live
/// `CameraPreviewUIView` so the torch control can reach `setTorch(_:)`.
///
/// **Why a custom representable.** iOS doesn't ship a SwiftUI QR-scan
/// primitive; `DataScannerViewController` is iPad-only. `AVCaptureSession`
/// is the canonical iOS API. Pure system code, no third-party scanner
/// library (Rule #3).
struct QRScannerCameraView: UIViewRepresentable {
    let onDecode: (String) -> Void
    var onReady: (CameraPreviewUIView) -> Void = { _ in }

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.start(onDecode: onDecode)
        // Hand the live view up so the torch control can toggle it. Defer
        // to the next runloop tick so the parent's `@State` write doesn't
        // happen during view construction.
        DispatchQueue.main.async { onReady(view) }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: ()) {
        uiView.stop()
    }
}

/// UIView that hosts the camera preview layer and runs the
/// `AVCaptureSession`. Owns the session's lifecycle.
final class CameraPreviewUIView: UIView {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var onDecode: ((String) -> Void)?
    private let delegate = MetadataDelegate()
    /// The active capture device — retained so the torch can be toggled
    /// after the session is running.
    private var captureDevice: AVCaptureDevice?

    /// Whether this device has an available torch — drives whether the
    /// scanner shows the Light control (simulator / front camera: no torch).
    var isTorchAvailable: Bool {
        guard let device = captureDevice else { return false }
        return device.hasTorch && device.isTorchAvailable
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    /// Toggle the device torch on/off. No-op on devices without a torch
    /// (front camera, simulator). Locks the device for configuration per
    /// the `AVCaptureDevice` torch contract.
    func setTorch(_ on: Bool) {
        guard let device = captureDevice, device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            // Torch lock can fail transiently; ignore — the chip just
            // doesn't toggle, which is the honest fallback.
        }
    }

    func start(onDecode: @escaping (String) -> Void) {
        self.onDecode = onDecode
        delegate.onDecode = onDecode

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        self.captureDevice = device
        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }

        let layer = (self.layer as? AVCaptureVideoPreviewLayer) ?? AVCaptureVideoPreviewLayer(session: session)
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer

        // Start session on a background queue — the API blocks until the
        // device opens.
        let sessionRef = session
        DispatchQueue.global(qos: .userInitiated).async {
            sessionRef.startRunning()
        }
    }

    func stop() {
        let sessionRef = session
        DispatchQueue.global(qos: .userInitiated).async {
            sessionRef.stopRunning()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

/// `AVCaptureMetadataOutputObjectsDelegate` that picks the first non-empty
/// payload and hands it to the closure. Stays alive for the lifetime of the
/// camera view.
final class MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onDecode: ((String) -> Void)?

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let payload = readable.stringValue,
                  !payload.isEmpty else { continue }
            onDecode?(payload)
            return
        }
    }
}
