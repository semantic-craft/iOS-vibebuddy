import SwiftUI
@preconcurrency import AVFoundation
import os
import VibeBuddyKit

private let scannerLog = Logger(subsystem: "com.vibebuddy.app", category: "scanner")

/// Camera QR scanner. Decodes the Mac's pairing QR (a `PairingPayload` JSON).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: @MainActor (PairingPayload) -> Void

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
            scannerLog.info("scanned string: \(string, privacy: .public)")
            guard let payload = try? JSONDecoder().decode(PairingPayload.self, from: Data(string.utf8)) else {
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
