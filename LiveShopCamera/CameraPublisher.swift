import AVFoundation
import Combine
import UIKit
import WebRTC

enum NativeLens: String, CaseIterable, Identifiable {
    case ultraWide, wide, front
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultraWide: return "0,5x — Ultra-angular traseira"
        case .wide: return "1x — Traseira"
        case .front: return "Frontal"
        }
    }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
    var deviceType: AVCaptureDevice.DeviceType { self == .ultraWide ? .builtInUltraWideCamera : .builtInWideAngleCamera }
    var device: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [deviceType], mediaType: .video, position: position).devices.first
    }
}

@MainActor
final class CameraPublisher: NSObject, ObservableObject {
    @Published var pairingURL = ""
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Leia o QR de iPhone via Wi-Fi na extensão"
    @Published private(set) var error = ""
    @Published private(set) var videoTrack: RTCVideoTrack?
    @Published private(set) var measuredFPS = "Aguardando"
    @Published var preset = "1280x720@30"
    @Published private(set) var selectedLens: NativeLens = .wide
    @Published private(set) var sentAudioPackets = 0
    @Published private(set) var sourceAudioLevel: Double = 0
    var availableLenses: [NativeLens] { NativeLens.allCases.filter { $0.device != nil } }
    let audio = AudioRouter()
    private lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoders = RTCDefaultVideoEncoderFactory()
        if let h264 = encoders.supportedCodecs().first(where: { $0.name.uppercased() == "H264" }) {
            encoders.preferredCodec = h264
        }
        return RTCPeerConnectionFactory(encoderFactory: encoders, decoderFactory: RTCDefaultVideoDecoderFactory(), audioDevice: audio.device)
    }()
    private var peer: RTCPeerConnection?
    private var capturer: RTCCameraVideoCapturer?
    private var audioTrack: RTCAudioTrack?
    private var signaling: Signaling?
    private var runID: UUID?
    private var pollTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var cursor = 0
    private var localCandidates: [Candidate] = []
    private var remoteCandidates: [RTCIceCandidate] = []
    private var offerPublished = false
    private var flushing = false
    private var negotiating = false
    private var position: AVCaptureDevice.Position { selectedLens.position }
    private var rearLens: NativeLens = .wide
    private var peerGeneration = UUID()
    private var width = 1280, height = 720, fps = 30
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audio.enforce(); self.syncAudio()
                self.audio.device.restartAfterRouteChange()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioTrack?.isEnabled = false
                    self.error = "O iOS interrompeu o áudio. Aguarde o fim da ligação/interrupção."
                } else { self.audio.enforce(); self.syncAudio() }
            }
        }
    }

    private func check(_ id: UUID) throws {
        guard runID == id, !Task.isCancelled else { throw CancellationError() }
    }
    private func telemetry() -> [String: Any] {
        ["captureClient": "ios-native", "streaming": running, "facingMode": position == .back ? "environment" : "user",
         "deviceLabel": "LiveShop Camera nativa — \(selectedLens.title)", "nativeLens": selectedLens.rawValue,
         "resolutionPreset": preset, "activeWidth": width, "activeHeight": height, "activeFps": fps,
         "audioEnabled": audio.allowed && audio.microphoneEnabled, "audioTrackPresent": audioTrack != nil,
         "audioDeviceLabel": audio.route, "audioError": audio.problem,
         "audioPacketsSent": sentAudioPackets, "sourceAudioLevel": sourceAudioLevel, "safariBackgrounded": false]
    }
    private func send(_ type: String, payload: [String: Any] = [:]) async throws {
        guard let signaling else { throw CancellationError() }
        try await signaling.send(type, payload: payload, telemetry: telemetry())
    }

    func start() {
        guard !busy, !running else { return }
        busy = true; error = ""
        let id = UUID(); runID = id
        actionTask = Task {
            defer { if runID == id { busy = false } }
            do {
                let pairing = try Pairing(pairingURL)
                let transport = Signaling(pairing: pairing); signaling = transport
                status = "Verificando conexão com o computador…"
                try await transport.validate(); try check(id)
                // Ignore commands/answers belonging to the previous phone session.
                cursor = (try await transport.poll(since: 0)).seq
                try check(id)
                let cameraOK = await AVCaptureDevice.requestAccess(for: .video)
                let micOK = await AVCaptureDevice.requestAccess(for: .audio)
                try check(id)
                guard cameraOK && micOK else { throw CameraError.message("Permita câmera e microfone em Ajustes > LiveShop Camera.") }
                try await audio.activate(); audio.recordTransition("Antes da câmera"); try check(id)
                let source = factory.videoSource()
                let track = factory.videoTrack(with: source, trackId: "lsc-native-video")
                videoTrack = track
                let capture = RTCCameraVideoCapturer(delegate: source); capturer = capture
                try await configureCapture(capture); audio.enforce(); audio.recordTransition("Câmera iniciada"); try check(id)
                let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
                    "googEchoCancellation": "false", "googAutoGainControl": "false", "googNoiseSuppression": "false"]))
                audioTrack = factory.audioTrack(with: audioSource, trackId: "lsc-native-audio")
                syncAudio(); running = true
                UIApplication.shared.isIdleTimerDisabled = true
                try await send("IPHONE_PAGE_OPENED")
                try await offer(id: id); audio.enforce(); audio.recordTransition("Conexão WebRTC criada"); try check(id)
                startPolling(id: id); startStats(id: id)
            } catch is CancellationError { }
            catch {
                guard runID == id else { return }
                let description = error.localizedDescription
                stop(); self.error = description + tlsHint(error)
            }
        }
    }

    private func tlsHint(_ error: Error) -> String {
        let code = (error as NSError).code
        return [-1200, -1202, -1203].contains(code)
            ? " Confirme o perfil CA atual do LiveShop e sua confiança total nos Ajustes do iPhone; o app não ignora certificados inválidos." : ""
    }

    private func configureCapture(_ capture: RTCCameraVideoCapturer) async throws {
        guard let device = selectedLens.device else {
            throw CameraError.message("Câmera indisponível.")
        }
        capture.captureSession.automaticallyConfiguresApplicationAudioSession = false
        let pieces = preset.split(separator: "@"); let dimensions = pieces[0].split(separator: "x")
        let targetW = Int32(dimensions.first.flatMap { Int($0) } ?? 1280)
        let targetH = Int32(dimensions.last.flatMap { Int($0) } ?? 720)
        let requestedFPS = pieces.count > 1 ? (Int(pieces[1]) ?? 30) : 30
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.min(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return abs(a.width - targetW) + abs(a.height - targetH) < abs(b.width - targetW) + abs(b.height - targetH)
        }) else { throw CameraError.message("Nenhum formato de câmera disponível.") }
        let maximum = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        fps = min(requestedFPS, Int(maximum))
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        width = Int(size.width); height = Int(size.height)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capture.startCapture(with: device, format: format, fps: fps) { failure in
                if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
            }
        }
    }

    private func offer(id: UUID) async throws {
        try check(id)
        guard !negotiating else { return }
        negotiating = true
        defer { if runID == id { negotiating = false } }
        peer?.delegate = nil; peer?.close()
        peerGeneration = UUID()
        offerPublished = false; flushing = false; localCandidates = []; remoteCandidates = []
        let config = RTCConfiguration(); config.iceServers = []
        config.sdpSemantics = .unifiedPlan; config.bundlePolicy = .maxBundle
        guard let pc = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self),
              let videoTrack, let audioTrack else { throw CameraError.message("Falha ao criar a conexão WebRTC nativa.") }
        peer = pc
        let transceiver = RTCRtpTransceiverInit(); transceiver.direction = .sendOnly; transceiver.streamIds = ["lsc-native"]
        guard let video = pc.addTransceiver(with: videoTrack, init: transceiver),
              pc.addTransceiver(with: audioTrack, init: transceiver) != nil else {
            throw CameraError.message("Falha ao adicionar câmera/microfone à conexão.")
        }
        let parameters = video.sender.parameters
        if let encoding = parameters.encodings.first {
            encoding.maxBitrateBps = NSNumber(value: width >= 1900 ? 4_000_000 : 2_500_000)
            encoding.maxFramerate = NSNumber(value: fps)
            video.sender.parameters = parameters
        }
        let description = try await withCheckedThrowingContinuation { (c: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, failure in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: failure ?? CameraError.message("Oferta SDP vazia.")) }
            }
        }
        try check(id)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(description) { failure in
                if let failure { c.resume(throwing: failure) } else { c.resume() }
            }
        }
        try check(id)
        try await send("SDP_OFFER", payload: ["sdp": ["type": "offer", "sdp": description.sdp]])
        try check(id); offerPublished = true
        try await flushCandidates(id: id)
        status = "Aguardando a extensão aceitar a câmera…"
    }

    private func flushCandidates(id: UUID) async throws {
        guard offerPublished, !flushing else { return }
        let generation = peerGeneration
        flushing = true; defer { if peerGeneration == generation { flushing = false } }
        while !localCandidates.isEmpty {
            try check(id)
            let candidate = localCandidates[0]
            let data = try JSONEncoder().encode(candidate)
            let payload = try JSONSerialization.jsonObject(with: data)
            try await send("ICE_CANDIDATE", payload: ["candidate": payload])
            try check(id)
            guard peerGeneration == generation else { return }
            localCandidates.removeFirst()
        }
    }

    private func startPolling(id: UUID) {
        pollTask?.cancel()
        pollTask = Task {
            while runID == id && !Task.isCancelled {
                do {
                    guard let signaling else { return }
                    let result = try await signaling.poll(since: cursor); try check(id)
                    for message in result.messages where message.seq > cursor {
                        try await handle(message, id: id); try check(id); cursor = message.seq
                    }
                    cursor = max(cursor, result.seq)
                    if !localCandidates.isEmpty { try await flushCandidates(id: id) }
                    try await Task.sleep(nanoseconds: 350_000_000)
                } catch is CancellationError { return }
                catch {
                    guard runID == id else { return }
                    self.error = error.localizedDescription
                    if (error as? CameraError) != nil { stop(); return }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func handle(_ message: HostMessage, id: UUID) async throws {
        switch message.type {
        case "SDP_ANSWER":
            guard let sdp = message.payload.sdp, sdp.type == "answer", let pc = peer else { return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp.sdp)) { failure in
                    if let failure { c.resume(throwing: failure) } else { c.resume() }
                }
            }
            try check(id)
            for candidate in remoteCandidates { try await add(candidate, to: pc) }
            remoteCandidates = []
        case "ICE_CANDIDATE":
            guard let c = message.payload.candidate, let pc = peer else { return }
            let candidate = RTCIceCandidate(sdp: c.candidate, sdpMLineIndex: c.sdpMLineIndex, sdpMid: c.sdpMid)
            if pc.remoteDescription == nil { remoteCandidates.append(candidate) } else { try await add(candidate, to: pc) }
        case "REQUEST_OFFER": try await offer(id: id)
        case "SWITCH_FACING":
            selectedLens = message.payload.facingMode.map { $0 == "user" ? .front : rearLens } ?? (position == .back ? .front : rearLens)
            try await restartCapture(id: id)
        case "SET_RESOLUTION":
            if let value = message.payload.resolutionPreset,
               ["1280x720@30", "1920x1080@30", "1280x720@60", "960x540@30"].contains(value) {
                preset = value; try await restartCapture(id: id)
            }
        case "SET_AUDIO_ENABLED": audio.microphoneEnabled = message.payload.audioEnabled ?? true; audio.enforce(); syncAudio()
        case "DISCONNECT": stop(notify: false)
        default: break
        }
    }

    private func add(_ candidate: RTCIceCandidate, to pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { failure in
                if let failure { c.resume(throwing: failure) } else { c.resume() }
            }
        }
    }
    private func restartCapture(id: UUID) async throws {
        guard let capture = capturer else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in capture.stopCapture { c.resume() } }
        try check(id); try await configureCapture(capture); try check(id)
        audio.enforce(); syncAudio(); try await send("TELEMETRY")
    }
    func flip() {
        guard !busy, let id = runID, running else { return }
        busy = true
        actionTask = Task {
            defer { busy = false }
            selectedLens = position == .back ? .front : rearLens
            do { try await restartCapture(id: id) } catch { self.error = error.localizedDescription }
        }
    }
    func syncAudio() { audioTrack?.isEnabled = audio.allowed && audio.microphoneEnabled }

    func changeLens(_ lens: NativeLens) {
        guard !busy, lens != selectedLens, lens.device != nil else { return }
        selectedLens = lens
        if lens != .front { rearLens = lens }
        guard running, let id = runID else { return }
        busy = true
        actionTask = Task {
            defer { busy = false }
            do { try await restartCapture(id: id) }
            catch { self.error = error.localizedDescription }
        }
    }

    func inspectAudio(allModes: Bool = false) {
        guard !busy, !running, !audio.checking else { return }
        busy = true
        actionTask = Task {
            defer { busy = false }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                self.error = "Permita o microfone em Ajustes > LiveShop Camera para consultar as entradas."
                return
            }
            guard !Task.isCancelled else { return }
            await audio.inspectInputs(allModes: allModes)
            self.error = ""
        }
    }

    private func startStats(id: UUID) {
        statsTask = Task {
            while runID == id && !Task.isCancelled {
                if let pc = peer {
                    pc.statistics { [weak self] report in
                        let video = report.statistics.values.first { $0.type == "outbound-rtp" && ($0.values["kind"] as? String) == "video" }
                        let rate = video?.values["framesPerSecond"] as? NSNumber
                        let outboundAudio = report.statistics.values.first { $0.type == "outbound-rtp" && ($0.values["kind"] as? String) == "audio" }
                        let sourceAudio = report.statistics.values.first { $0.type == "media-source" && ($0.values["kind"] as? String) == "audio" }
                        let packets = outboundAudio?.values["packetsSent"] as? NSNumber
                        let level = sourceAudio?.values["audioLevel"] as? NSNumber
                        Task { @MainActor in
                            guard let self, self.runID == id else { return }
                            self.measuredFPS = rate.map { String(format: "%.1f FPS enviados", $0.doubleValue) } ?? "Medindo FPS…"
                            self.sentAudioPackets = packets?.intValue ?? 0
                            self.sourceAudioLevel = level?.doubleValue ?? 0
                        }
                    }
                    audio.enforce(); syncAudio()
                    try? await send("TELEMETRY")
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    func stop(notify: Bool = true) {
        let transport = signaling, snapshot = telemetry()
        runID = nil; actionTask?.cancel(); pollTask?.cancel(); statsTask?.cancel()
        peerGeneration = UUID(); flushing = false; negotiating = false
        peer?.delegate = nil; peer?.close(); peer = nil
        capturer?.stopCapture(); capturer = nil; videoTrack = nil; audioTrack = nil
        audio.stop(); running = false; busy = false; cursor = 0
        measuredFPS = "Aguardando"
        sentAudioPackets = 0; sourceAudioLevel = 0
        offerPublished = false; localCandidates = []; remoteCandidates = []
        signaling = nil; UIApplication.shared.isIdleTimerDisabled = false
        status = "Desconectado"
        Task {
            if notify { try? await transport?.send("IPHONE_STOPPED", telemetry: snapshot.merging(["streaming": false]) { _, new in new }) }
            transport?.close()
        }
    }
}

extension CameraPublisher: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard self.peer === peerConnection, let id = self.runID else { return }
            self.localCandidates.append(Candidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
            do { try await self.flushCandidates(id: id) } catch { self.error = error.localizedDescription }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard self.peer === peerConnection else { return }
            switch newState {
            case .connected, .completed: self.status = "Conectado diretamente à extensão"; self.error = ""; self.audio.enforce(); self.syncAudio()
            case .failed: self.error = "Falha na conexão local. Confira o Wi-Fi e reconecte."
            case .disconnected: self.status = "Wi-Fi interrompido — aguardando…"
            default: break
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
