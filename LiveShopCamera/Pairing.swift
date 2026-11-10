import Foundation

enum CameraError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct Pairing {
    let baseURL: URL
    let token: String

    init(_ text: String) throws {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", let host = components.host,
              components.user == nil, components.password == nil,
              components.path == "/iphone" || components.path == "/",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty, token.count <= 256 else {
            throw CameraError.message("Leia o QR de iPhone via Wi-Fi da extensão ou cole sua URL HTTPS completa, com token.")
        }
        // Pair only to the explicitly selected LAN host. Never send the token to VDO or a cloud relay.
        let parts = host.split(separator: ".").compactMap { Int($0) }
        let privateIPv4 = parts.count == 4 && parts.allSatisfy { (0...255).contains($0) } &&
            (parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) ||
             (parts[0] == 172 && (16...31).contains(parts[1])))
        guard privateIPv4 || host.lowercased().hasSuffix(".local") else {
            throw CameraError.message("O pareamento deve apontar para o IP privado ou nome .local do computador na mesma rede Wi-Fi.")
        }
        var base = URLComponents()
        base.scheme = "https"; base.host = host; base.port = components.port ?? 8443
        guard let url = base.url else { throw CameraError.message("Endereço local inválido.") }
        self.baseURL = url; self.token = token
    }

    func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var url = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        url.queryItems = query.isEmpty ? nil : query
        return url.url!
    }
}

struct SDP: Codable { let type: String; let sdp: String }
struct Candidate: Codable { let candidate: String; let sdpMid: String?; let sdpMLineIndex: Int32 }
struct HostPayload: Decodable {
    let sdp: SDP?
    let candidate: Candidate?
    let facingMode: String?
    let resolutionPreset: String?
    let audioEnabled: Bool?
}
struct HostMessage: Decodable { let seq: Int; let type: String; let payload: HostPayload }
struct PollResult: Decodable { let ok: Bool; let seq: Int; let messages: [HostMessage] }

// A paired session follows normal system TLS validation. No "accept all certificates" delegate.
// Refuse redirects so a compromised server cannot redirect a POST containing the pairing token.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class Signaling {
    let pairing: Pairing
    private let session: URLSession
    init(pairing: Pairing) {
        self.pairing = pairing
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }
    private func request(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CameraError.message("Resposta local inválida.") }
        guard http.statusCode != 403 else { throw CameraError.message("Pareamento expirou. Gere e leia um novo QR na extensão.") }
        guard (200...299).contains(http.statusCode) else { throw CameraError.message("Servidor local respondeu HTTP \(http.statusCode).") }
        return data
    }
    func validate() async throws {
        _ = try await request(URLRequest(url: pairing.endpoint("api/iphone/session", query: [.init(name: "token", value: pairing.token)])))
    }
    func send(_ type: String, payload: [String: Any] = [:], telemetry: [String: Any]) async throws {
        var req = URLRequest(url: pairing.endpoint("api/iphone/signal"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": pairing.token, "type": type, "payload": payload, "telemetry": telemetry])
        _ = try await request(req)
    }
    func poll(since: Int) async throws -> PollResult {
        let data = try await request(URLRequest(url: pairing.endpoint("api/iphone/poll", query: [
            .init(name: "token", value: pairing.token), .init(name: "since", value: String(since))])))
        return try JSONDecoder().decode(PollResult.self, from: data)
    }
}
