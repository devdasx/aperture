import SwiftUI
// `@preconcurrency` — AVFoundation's capture types predate Sendable
// annotation; `AVCaptureSession.start/stopRunning` are documented
// thread-safe and must run off-main (they block). This is the
// compiler-sanctioned bridge until Apple annotates the framework.
@preconcurrency import AVFoundation

/// The WalletConnect QR-scan sheet. Wraps an `AVCaptureSession` in
/// a `UIViewRepresentable` so the camera preview reads as native,
/// and routes the first decoded QR payload starting with `wc:`
/// back to the caller.
///
/// **Sheet shape (Rule #15).** `NavigationStack { … }` with
/// `.navigationTitle("Scan WalletConnect QR")` on `.inline`.
/// Cancel in the leading toolbar slot dismisses without firing.
///
/// **Permissions.** The camera permission prompt fires the first
/// time the scanner appears. If the user has denied the permission,
/// the sheet renders a calm "Camera access needed" surface with a
/// "Open Settings" link instead of crashing or silently failing.
///
/// **Honesty (Rule #16).** Aperture explicitly says what the
/// camera is for in `NSCameraUsageDescription` — "Scan
/// WalletConnect QR codes from dApps." Not "to verify your
/// identity" or any other claim we don't fulfill.
struct BrowserQRScanSheet: View {
    let onScan: (String) -> Void

    @State private var permissionState: PermissionState = .pending
    @State private var hasDelivered: Bool = false

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
                UniColors.Background.primary
                    .ignoresSafeArea()

                switch permissionState {
                case .pending:
                    waitingSurface
                case .granted:
                    scannerSurface
                case .denied:
                    deniedSurface
                }
            }
            .navigationTitle("Scan WalletConnect QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await resolvePermission()
            }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var waitingSurface: some View {
        VStack(spacing: UniSpacing.m) {
            ProgressView()
            UniBody(
                text: "Requesting camera access…",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
    }

    @ViewBuilder
    private var scannerSurface: some View {
        ZStack {
            QRScannerCameraView { decoded in
                guard !hasDelivered else { return }
                guard decoded.hasPrefix("wc:") else { return }
                hasDelivered = true
                onScan(decoded)
            }
            .ignoresSafeArea()

            // Calm framing overlay — a rounded rectangle reticle
            // in the center plus an instructional caption above.
            VStack(spacing: UniSpacing.l) {
                Spacer()
                Image(systemName: "viewfinder")
                    .font(.system(size: 220, weight: .ultraLight))
                    .foregroundStyle(UniColors.Text.onMedia.opacity(0.4))
                    .accessibilityHidden(true)
                Spacer()
                UniBody(
                    text: "Point your camera at a WalletConnect QR code from any dApp.",
                    alignment: .center,
                    color: UniColors.Text.onMedia
                )
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.xl)
            }
        }
    }

    @ViewBuilder
    private var deniedSurface: some View {
        VStack(spacing: UniSpacing.l) {
            Image(systemName: "video.slash")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(UniColors.Icon.secondary)

            UniHeadline(
                text: "Camera access needed",
                alignment: .center
            )

            UniBody(
                text: "Aperture uses the camera to scan WalletConnect QR codes. Enable camera access in Settings to continue.",
                alignment: .center,
                color: UniColors.Text.secondary
            )

            UniButton(
                title: "Open Settings",
                variant: .primary,
                systemImage: "gearshape"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }
        .padding(.horizontal, UniSpacing.l)
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

// MARK: - QRScannerCameraView (AVCaptureSession wrapper)

/// `UIViewRepresentable` wrapping an `AVCaptureSession` with a
/// `AVCaptureMetadataOutput` configured for `qr` codes. Streams
/// every decoded payload to the `onDecode` callback; the parent
/// filters for `wc:` prefix and delivers the first match.
///
/// **Why a custom representable.** iOS doesn't ship a SwiftUI
/// QR-scan primitive; `DataScannerViewController` is iPad-only.
/// `AVCaptureSession` is the canonical iOS API. Pure system code,
/// no third-party scanner library (Rule #3).
struct QRScannerCameraView: UIViewRepresentable {
    let onDecode: (String) -> Void

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.start(onDecode: onDecode)
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

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    func start(onDecode: @escaping (String) -> Void) {
        self.onDecode = onDecode
        delegate.onDecode = onDecode

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
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

        // Start session on a background queue — the API blocks
        // until the device opens.
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

/// `AVCaptureMetadataOutputObjectsDelegate` that picks the first
/// non-empty payload and hands it to the closure. Stays alive for
/// the lifetime of the camera view.
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
