import AVFoundation
import Combine
import WebRTC

struct AudioInput: Identifiable { let id: String; let name: String; let external: Bool }

@MainActor
final class AudioRouter: ObservableObject {
    @Published private(set) var inputs: [AudioInput] = []
    @Published private(set) var route = "Microfone ainda não ativado"
    @Published private(set) var problem = ""
    @Published var selectedID = ""
    @Published var requireExternal = true
    @Published var microphoneEnabled = true
    private(set) var allowed = false
    private var activated = false
    private let rtc = RTCAudioSession.sharedInstance()

    init() { rtc.useManualAudio = true; rtc.isAudioEnabled = false }

    private func isExternal(_ input: AVAudioSessionPortDescription) -> Bool {
        [.usbAudio, .headsetMic, .lineIn].contains(input.portType)
    }

    func activate() throws {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.categoryOptions = []
        config.mode = AVAudioSession.Mode.videoChat.rawValue
        config.sampleRate = 48_000
        config.ioBufferDuration = 0.01
        RTCAudioSessionConfiguration.setWebRTC(config)
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        try rtc.setConfiguration(config, active: true)
        activated = true
        try selectRoute()
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
        guard activated else { refresh(); return }
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do { try selectRoute() }
        catch { allowed = false; rtc.isAudioEnabled = false; problem = error.localizedDescription; refresh() }
    }

    func stop() {
        rtc.isAudioEnabled = false; allowed = false
        guard activated else { return }
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        try? rtc.setActive(false)
        activated = false; refresh()
    }
}
