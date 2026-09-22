import SwiftUI
@preconcurrency import AVFoundation
import os
import VibeBuddyKit

private let scannerLog = Logger(subsystem: "com.vibebuddy.app", category: "scanner")

/// Camera QR scanner. Decodes the Mac's pairing QR (a `PairingPayload` JSON).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: @MainActor (PairingPayload) -> Void

    /// The one gate between a camera frame and `ConnectionStore`. A code that
    /// does not decode, or that carries an address or token the app would
    /// refuse, returns nil here and never reaches the store — so a bad scan
    /// cannot disturb the Mac already saved on this phone.
    nonisolated static func pairing(from code: String) -> PairingPayload? {
        guard let payload = try? JSONDecoder().decode(PairingPayload.self, from: Data(code.utf8)),
              payload.isValidConnection else { return nil }
        return payload
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onScan: @MainActor (PairingPayload) -> Void
        private var handled = false

        init(onScan: @escaping @MainActor (PairingPayload) -> Void) { self.onScan = onScan }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let string = object.stringValue else {
                scannerLog.info("metadata callback but no string")
                return
            }
            scannerLog.info("scanned pairing code")
            guard let payload = QRScannerView.pairing(from: string) else {
                scannerLog.error("decode to PairingPayload FAILED")
                return
            }
            Task { @MainActor in
                guard !self.handled else { return }
                self.handled = true
                scannerLog.info("decoded ok; pairing host=\(payload.host, privacy: .public)")
                self.onScan(payload)
            }
        }
    }
}

final class ScannerViewController: UIViewController {
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.vibebuddy.scanner.session")
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        scannerLog.info("camera auth status=\(status.rawValue)")
        switch status {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                scannerLog.info("camera permission granted=\(granted)")
                guard granted else { return }
                DispatchQueue.main.async { self?.configureSession() }
            }
        default:
            scannerLog.error("camera NOT authorized — enable in Settings")
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            scannerLog.error("no camera input available")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            scannerLog.error("cannot add metadata output")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr)
            ? [.qr] : output.availableMetadataObjectTypes
        scannerLog.info("session configured; qr supported=\(output.metadataObjectTypes.contains(.qr))")

        sessionQueue.async { [session] in
            session.startRunning()
            scannerLog.info("session running=\(session.isRunning)")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

/// Shared by initial setup and re-pairing. Cancelling never removes the saved Mac.
struct PairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    var onManualEntry: (() -> Void)? = nil
    var onScan: ((PairingPayload) -> Void)? = nil
    @State private var showHelp = false
    @State private var scannerID = UUID()
    @StateObject private var check = RemoteConnectionAttempt()

    var body: some View {
        NavigationStack {
            QRScannerView { payload in
                if let onScan {
                    onScan(payload)
                    dismiss()
                } else {
                    let unchanged = connection.pairing == payload
                    check.start(payload, connection: connection) {
                        dashboard.confirmPairing()
                        if unchanged { dashboard.start(payload) }
                        dismiss()
                    }
                }
            }
            .id(scannerID)
            .ignoresSafeArea()
            .safeAreaInset(edge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if check.isChecking {
                            ProgressView("Checking connection…")
                        }
                        if case .failure(let failure) = check.phase {
                            if failure == .unavailable {
                                Text("Could not receive live Mac status. Check the network and wake your Mac. Your saved pairing has not changed.")
                            } else {
                                Text(failure.message)
                            }
                            Button("Scan again") {
                                check.reset()
                                scannerID = UUID()
                            }
                        }
                        Text("On your Mac, open Devices & connection and choose Show connection code. Scan the code here. Cancelling keeps your current pairing.")
                            .font(CompanionType.font(15))
                        DisclosureGroup("Can't find the QR code?", isExpanded: $showHelp) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Install the companion on your Mac, open Devices & connection, then choose Show connection code. Use the same local network or connect both devices to Tailscale.")
                                MacCompanionDownloadActions()
                            }.padding(.top, 12)
                        }
                        if let onManualEntry {
                            Button("Enter address manually") { check.cancel(); onManualEntry(); dismiss() }
                        }
                    }.padding()
                }
                .frame(maxHeight: showHelp || check.phase != .idle ? 360 : 160)
                .background(.regularMaterial)
            }
            .navigationTitle("Scan pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { check.cancel(); dismiss() }
                }
            }
        }
        .onDisappear { check.cancel() }
    }
}
