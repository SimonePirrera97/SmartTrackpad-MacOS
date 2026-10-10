import AVFoundation
import SwiftUI
import VisionKit

@MainActor
final class PairingScannerModel: ObservableObject {
    @Published var presented = false
    @Published var error: String?

    func present() async {
        error = nil
        guard DataScannerViewController.isSupported else {
            error = "QR scanning is unavailable on this device. Enter the address and key manually."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable else {
            error = "Camera access is unavailable. Enable it in Settings or enter the address and key manually."
            return
        }
        presented = true
    }
}

struct PairingScannerView: View {
    var onInvitation: (PairingInvitation) -> Void
    var onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScannerCamera(onInvitation: onInvitation, onError: onError)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan your Mac’s pairing code")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct ScannerCamera: UIViewControllerRepresentable {
    var onInvitation: (PairingInvitation) -> Void
    var onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerContainer {
        ScannerContainer(onInvitation: onInvitation, onError: onError)
    }
    func updateUIViewController(_ controller: ScannerContainer, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerContainer, coordinator: ()) { controller.scanner.stopScanning() }
}

final class ScannerContainer: UIViewController, DataScannerViewControllerDelegate {
    let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced, recognizesMultipleItems: false,
        isGuidanceEnabled: true, isHighlightingEnabled: true)
    private var completed = false
    let onInvitation: (PairingInvitation) -> Void
    let onError: (String) -> Void

    init(onInvitation: @escaping (PairingInvitation) -> Void, onError: @escaping (String) -> Void) {
        self.onInvitation = onInvitation; self.onError = onError
        super.init(nibName: nil, bundle: nil)
        scanner.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        view.addSubview(scanner.view)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        scanner.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do { try scanner.startScanning() }
        catch { onError("Could not start camera scanning. Use manual pairing instead.") }
    }
    override func viewWillDisappear(_ animated: Bool) { scanner.stopScanning(); super.viewWillDisappear(animated) }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems { accept(item) }
    }
    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { accept(item) }
    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in updatedItems { accept(item) }
    }
    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        onError("Camera scanning became unavailable. Use manual pairing instead.")
    }
    private func accept(_ item: RecognizedItem) {
        guard !completed, case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
              let invitation = try? PairingInvitation.decode(payload) else { return }
        completed = true
        scanner.stopScanning()
        onInvitation(invitation)
    }
}
