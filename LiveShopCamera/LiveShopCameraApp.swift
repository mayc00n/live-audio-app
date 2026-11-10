import SwiftUI

@main
@MainActor
struct LiveShopCameraApp: App {
    @StateObject private var camera = CameraPublisher()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            CameraScreen(camera: camera, audio: camera.audio)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { state in
                    if state == .background { camera.stop() }
                }
        }
    }
}
