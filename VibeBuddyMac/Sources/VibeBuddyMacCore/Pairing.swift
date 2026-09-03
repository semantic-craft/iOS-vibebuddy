import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreGraphics
#endif
import VibeBuddyKit

/// Builds the pairing payload and its QR image. The phone scans the QR, decodes
/// the JSON into a `PairingPayload`, and connects.
public enum Pairing {

    public static func payload(host: String, port: Int, token: String, macName: String? = nil) -> PairingPayload {
        PairingPayload(host: host, port: port, token: token, macName: macName)
    }

    /// The exact JSON string encoded into the QR (and decoded by the phone).
    public static func qrJSONString(for payload: PairingPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

#if canImport(CoreImage)
    /// Render a string into a QR CGImage (10x scaled, black-on-white).
    /// CIQRCodeGenerator outputs black modules on a *transparent* background, so
    /// we composite over opaque white — otherwise it's invisible/unscannable on
    /// a dark-mode menu background.
    public static func qrImage(from string: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let qr = filter.outputImage else { return nil }
        let white = CIImage(color: .white).cropped(to: qr.extent)
        let onWhite = qr.composited(over: white)
        let scaled = onWhite.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
#endif
}
