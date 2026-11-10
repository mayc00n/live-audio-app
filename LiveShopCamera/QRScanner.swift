import AVFoundation
import SwiftUI

struct QRScanner: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> QRController { QRController(completion: completion) }
    func updateUIViewController(_ controller: QRController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRController, coordinator: ()) { controller.stop() }
}

final class QRController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "liveshop.qr")
    private var preview: AVCaptureVideoPreviewLayer?
    private var completed = false
    private let completion: (Result<String, Error>) -> Void
    init(completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let close = UIButton(type: .system); close.setTitle("Cancelar", for: .normal)
        close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20), close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            guard !self.completed else { return }
            guard allowed else { self.finish(.failure(CameraError.message("Permita a câmera nos Ajustes para ler o QR."))); return }
            self.queue.async {
                do {
                    guard !self.completed else { return }
                    guard let camera = AVCaptureDevice.default(for: .video) else { throw CameraError.message("Câmera indisponível.") }
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(input) else { throw CameraError.message("Câmera ocupada. Feche o VDO e tente novamente.") }
                    self.session.addInput(input)
                    let output = AVCaptureMetadataOutput()
                    guard self.session.canAddOutput(output) else { throw CameraError.message("Leitor QR indisponível.") }
                    self.session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                    DispatchQueue.main.async {
                        let layer = AVCaptureVideoPreviewLayer(session: self.session); layer.videoGravity = .resizeAspectFill
                        layer.frame = self.view.bounds; self.view.layer.insertSublayer(layer, at: 0); self.preview = layer
                    }
                    self.session.startRunning()
                } catch { self.finish(.failure(error)) }
            }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let text = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        do { _ = try Pairing(text); finish(.success(text)) } catch { finish(.failure(error)) }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    @objc private func cancel() { completed = true; stop(); dismiss(animated: true) }
    private func finish(_ result: Result<String, Error>) {
        DispatchQueue.main.async {
            guard !self.completed else { return }; self.completed = true
            self.queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                DispatchQueue.main.async { self.completion(result) }
            }
        }
    }
}
