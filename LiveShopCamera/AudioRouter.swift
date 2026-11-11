import AVFoundation
import Combine
import UIKit
import WebRTC

struct AudioInput: Identifiable { let id: String; let name: String; let external: Bool }

enum CaptureAudioMode: String, CaseIterable, Identifiable {
    case recording, communication, automatic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recording: return "Gravação / lapela"
        case .communication: return "Comunicação"
        case .automatic: return "Padrão do iOS"
        }
    }
    var sessionMode: AVAudioSession.Mode {
        switch self {
        case .recording: return .videoRecording
        case .communication: return .voiceChat
        case .automatic: return .default
        }
    }
}

@MainActor
final class AudioRouter: ObservableObject {
    @Published private(set) var inputs: [AudioInput] = []
    @Published private(set) var route = "Microfone ainda não ativado"
    @Published private(set) var problem = ""
    @Published var selectedID = ""
    @Published var requireExternal = true
    @Published var microphoneEnabled = true
    @Published var captureMode: CaptureAudioMode = .recording
    @Published private(set) var diagnostic = "Nenhuma verificação realizada."
    @Published private(set) var checking = false
    private(set) var allowed = false
    private var activated = false
    private var generation = 0
    private let rtc = RTCAudioSession.sharedInstance()

    init() { rtc.useManualAudio = true; rtc.isAudioEnabled = false }

    private func isExternal(_ input: AVAudioSessionPortDescription) -> Bool {
        [.usbAudio, .headsetMic, .lineIn].contains(input.portType)
    }

    private func configure() throws {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.categoryOptions = [.allowBluetooth, .mixWithOthers]
        config.mode = captureMode.sessionMode.rawValue
        config.sampleRate = 48_000
        config.ioBufferDuration = 0.01
        RTCAudioSessionConfiguration.setWebRTC(config)
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        if activated { try rtc.setConfiguration(config) }
        else { try rtc.setConfiguration(config, active: true) }
        activated = true
    }

    func activate() async throws {
        try configure()
        let current = generation
        // Wired devices can appear after the audio session's activation notification.
        for attempt in 0..<5 {
            try Task.checkCancellation()
            guard current == generation else { throw CancellationError() }
            refresh()
            if !requireExternal || inputs.contains(where: { $0.external }) || attempt == 4 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do { try selectRoute(); captureDiagnostic() }
        catch { captureDiagnostic(); throw error }
    }

    // This remains usable after a failed connection: configure() actually reactivates
    // AVAudioSession instead of enumerating the inactive session's empty inputs.
    func inspectInputs(allModes: Bool = false) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let current = generation
        let selectedMode = captureMode
        var reports: [String] = []
        for mode in allModes ? CaptureAudioMode.allCases : [selectedMode] {
            guard current == generation, !Task.isCancelled else { return }
            captureMode = mode
            do {
                try configure()
                try await Task.sleep(nanoseconds: 350_000_000)
                guard current == generation, !Task.isCancelled else { return }
                refresh(); reports.append(snapshot())
            } catch { reports.append("Modo: \(mode.title)\nErro: \(error.localizedDescription)") }
        }
        captureMode = selectedMode
        guard current == generation, !Task.isCancelled else { return }
        do {
            try configure()
            try await Task.sleep(nanoseconds: 200_000_000)
            guard current == generation, !Task.isCancelled else { return }
            refresh()
        } catch { problem = error.localizedDescription }
        diagnostic = "LiveShop Camera 0.1.1 — diagnóstico local\niOS: \(UIDevice.current.systemVersion)\n\n" + reports.joined(separator: "\n\n") +
            "\n\nSem gravação, token de pareamento ou identificadores de dispositivo. Nenhum áudio é enviado por este diagnóstico."
        if requireExternal && !inputs.contains(where: { $0.external }) {
            problem = "O iOS não listou USB, fone com microfone ou entrada de linha neste modo. Veja o diagnóstico dos três modos; o receptor pode aparecer com outra identificação."
        } else { problem = "" }
    }

    private func snapshot() -> String {
        let session = AVAudioSession.sharedInstance()
        let devices = session.availableInputs ?? []
        let descriptions = devices.map { "• \($0.portName) | tipo: \($0.portType.rawValue) | externo reconhecido: \(isExternal($0) ? "sim" : "não")" }
        return "Modo: \(captureMode.title)\nCategoria: \(session.category.rawValue)\nModo iOS: \(session.mode.rawValue)\nEntradas visíveis: \(devices.count)\n" +
            descriptions.joined(separator: "\n") + "\nRota informada pelo iOS: \(route)\nTaxa: \(Int(session.sampleRate)) Hz"
    }

    private func captureDiagnostic() {
        diagnostic = "LiveShop Camera 0.1.1\n" + snapshot()
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        inputs = (session.availableInputs ?? []).map { .init(id: $0.uid, name: $0.portName, external: isExternal($0)) }
        let actual = session.currentRoute.inputs
        route = actual.isEmpty ? "Sem entrada ativa" : actual.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
    }

    private func selectRoute() throws {
        let session = AVAudioSession.sharedInstance()
        refresh()
        let available = session.availableInputs ?? []
        let desired: AVAudioSessionPortDescription?
        if !selectedID.isEmpty {
            desired = available.first(where: { $0.uid == selectedID })
        } else if requireExternal {
            desired = available.first(where: isExternal)
        } else {
            desired = available.first(where: { $0.portType == .builtInMic }) ?? available.first
        }
        guard let desired else {
            throw CameraError.message("A entrada escolhida não está disponível. Conecte o receptor Lightning e toque em Atualizar entradas.")
        }
        guard !requireExternal || isExternal(desired) else {
            throw CameraError.message("A entrada escolhida é interna. Selecione a lapela ou desative Exigir microfone externo para testar sem ela.")
        }
        if session.preferredInput?.uid != desired.uid { try session.setPreferredInput(desired) }
        refresh()
        guard session.currentRoute.inputs.contains(where: { $0.uid == desired.uid }) else {
            throw CameraError.message("O iOS ainda não ativou a entrada escolhida. O áudio foi bloqueado para não enviar o microfone interno por engano.")
        }
        allowed = true; problem = ""
        if rtc.isAudioEnabled != microphoneEnabled { rtc.isAudioEnabled = microphoneEnabled }
    }

    func enforce() {
        guard activated, !checking else { refresh(); return }
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do { try selectRoute() }
        catch { allowed = false; rtc.isAudioEnabled = false; problem = error.localizedDescription; refresh() }
    }

    func stop() {
        generation += 1
        rtc.isAudioEnabled = false; allowed = false
        guard activated else { return }
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        try? rtc.setActive(false)
        activated = false; refresh()
    }
}
