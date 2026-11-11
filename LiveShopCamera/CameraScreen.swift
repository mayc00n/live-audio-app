import SwiftUI
import UIKit
import WebRTC

struct CameraScreen: View {
    @ObservedObject var camera: CameraPublisher
    @ObservedObject var audio: AudioRouter
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(camera.status).font(.headline).foregroundStyle(.mint)
                    NativePreview(track: camera.videoTrack)
                        .frame(height: 320).background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
                    if !camera.error.isEmpty { Text(camera.error).foregroundStyle(.orange).textSelection(.enabled) }
                    GroupBox("Conexão com o computador") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("URL HTTPS do QR da extensão", text: $camera.pairingURL, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textContentType(.URL).disabled(camera.running || camera.busy)
                            Button("Ler QR da extensão", systemImage: "qrcode.viewfinder") { scanning = true }
                                .disabled(camera.running || camera.busy)
                            Text("Use o QR de iPhone via Wi-Fi, com o servidor local aberto e ambos na mesma rede.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GroupBox("Microfone de lapela") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Modo de captura", selection: $audio.captureMode) {
                                ForEach(CaptureAudioMode.allCases) { mode in Text(mode.title).tag(mode) }
                            }.disabled(camera.running || camera.busy)
                            Toggle("Exigir microfone externo", isOn: $audio.requireExternal)
                                .onChange(of: audio.requireExternal) { _ in audio.enforce(); camera.syncAudio() }
                            Picker("Entrada", selection: $audio.selectedID) {
                                Text("Automático").tag("")
                                ForEach(audio.inputs) { input in Text(input.name + (input.external ? " • externo" : " • interno")).tag(input.id) }
                                if !audio.selectedID.isEmpty && !audio.inputs.contains(where: { $0.id == audio.selectedID }) {
                                    Text("Entrada desconectada").tag(audio.selectedID)
                                }
                            }.onChange(of: audio.selectedID) { _ in audio.enforce(); camera.syncAudio() }
                            Button("Atualizar entradas") {
                                if camera.running { audio.enforce(); camera.syncAudio() }
                                else { camera.inspectAudio() }
                            }.disabled(camera.busy)
                            Button("Diagnosticar lapela nos três modos") { camera.inspectAudio(allModes: true) }
                                .disabled(camera.running || camera.busy)
                            Text("Entradas disponíveis: \(audio.inputs.count)").font(.caption)
                            DisclosureGroup("Ver diagnóstico do microfone") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(audio.diagnostic).font(.caption).textSelection(.enabled)
                                    Button("Copiar diagnóstico") { UIPasteboard.general.string = audio.diagnostic }
                                }
                            }
                            Toggle("Enviar áudio", isOn: $audio.microphoneEnabled)
                                .onChange(of: audio.microphoneEnabled) { _ in audio.enforce(); camera.syncAudio() }
                            Text("Entrada ativa: \(audio.route)").font(.callout).textSelection(.enabled)
                            if !audio.problem.isEmpty { Text(audio.problem).font(.callout).foregroundStyle(.orange) }
                            Text("Conecte o receptor antes de iniciar. Se a lapela cair, o áudio é bloqueado em vez de substituir pelo microfone interno. Confirme a captura falando na lapela e conferindo o gerenciador.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Qualidade", selection: $camera.preset) {
                        Text("HD • 30 FPS").tag("1280x720@30")
                        Text("Full HD • 30 FPS").tag("1920x1080@30")
                        Text("HD • 60 FPS").tag("1280x720@60")
                        Text("Leve • 30 FPS").tag("960x540@30")
                    }.disabled(camera.running || camera.busy)
                    Text(camera.measuredFPS).font(.caption).monospacedDigit()
                    HStack {
                        Button(camera.running || camera.busy ? "Encerrar" : "Conectar e transmitir") {
                            if camera.running || camera.busy { camera.stop() } else { camera.start() }
                        }.buttonStyle(.borderedProminent).tint(camera.running ? .red : .mint)
                        Button("Trocar câmera", systemImage: "arrow.triangle.2.circlepath.camera") { camera.flip() }
                            .disabled(!camera.running || camera.busy)
                    }
                    Text("Mantenha o app aberto e o iPhone desbloqueado. Câmera e áudio seguem por WebRTC diretamente ao navegador do computador. O servidor local apenas faz o pareamento.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("LiveShop Camera 0.1.1")
        }
        .sheet(isPresented: $scanning) {
            QRScanner { result in
                switch result {
                case .success(let url): camera.pairingURL = url
                case .failure(let failure): camera.pairingURL = ""; scannerError = failure.localizedDescription
                }
                scanning = false
            }.ignoresSafeArea()
        }
        .alert("Não foi possível ler o QR", isPresented: Binding(get: { !scannerError.isEmpty }, set: { if !$0 { scannerError = "" } })) {
            Button("OK") { scannerError = "" }
        } message: { Text(scannerError) }
    }
    @State private var scannerError = ""
}

struct NativePreview: UIViewRepresentable {
    let track: RTCVideoTrack?
    final class Coordinator { var current: RTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero); view.videoContentMode = .scaleAspectFit
        return view
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        guard context.coordinator.current !== track else { return }
        context.coordinator.current?.remove(view)
        context.coordinator.current = track; track?.add(view)
    }
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) { coordinator.current?.remove(view) }
}
