import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class QRRenderer: ObservableObject {
    @Published var image: CGImage?
    @Published var error: String?

    func render(_ payload: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else {
            image = nil; error = "QR filter produced no output"; return
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        image = CIContext().createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace)
            ?? CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent,
                format: .RGBA8, colorSpace: colorSpace)
        error = image == nil ? "QR image could not be rendered. Use Copy pairing key instead." : nil
    }
}

struct PairingQRCode: View {
    let payload: String
    @StateObject private var renderer = QRRenderer()
    var body: some View {
        Group {
            if let image = renderer.image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                    .scaledToFit().frame(width: 220, height: 220)
                    .padding(16).background(.white)
                    .accessibilityLabel("Pairing QR code. Scan with Smart Trackpad on the iPad.")
            } else if let error = renderer.error {
                Text(error).font(.footnote)
            }
        }
        .onChange(of: payload, initial: true) { _, payload in renderer.render(payload) }
    }
}

final class PairingDisplayModel: ObservableObject {
    @Published var host = ""
    @Published var showCode = false
}
