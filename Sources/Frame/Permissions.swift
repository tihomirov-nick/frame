import AppKit
import AVFoundation
import FrameCore

/// The three permissions of a recording: the screen (required), the camera and the microphone (when switched on).
enum Permission: CaseIterable {
    case screen, camera, microphone

    var granted: Bool {
        switch self {
        case .screen: return CGPreflightScreenCaptureAccess()
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    var title: String {
        switch self {
        case .screen: return L("Запись экрана")
        case .camera: return L("Камера")
        case .microphone: return L("Микрофон")
        }
    }

    var help: String {
        switch self {
        case .screen:
            return L("Без этого разрешения macOS не даёт записывать экран. Иногда оно начинает работать только после перезапуска приложения")
        case .camera:
            return L("Для пузыря с камерой. Видео с камеры пишется в отдельный файл и остаётся на этом Mac")
        case .microphone:
            return L("Для голоса в записи. Звук остаётся на этом Mac")
        }
    }

    private static let screenAskedKey = "screenPermissionAsked"

    /// The list of this permission in System Settings → Privacy & Security.
    private var anchor: String {
        switch self {
        case .screen: return "Privacy_ScreenCapture"
        case .camera: return "Privacy_Camera"
        case .microphone: return "Privacy_Microphone"
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks for the permission: macOS shows its own question the first time, after that only System Settings can
    /// change the answer, so they open. True when the permission is there.
    @MainActor
    func request() async -> Bool {
        switch self {
        case .screen:
            if CGPreflightScreenCaptureAccess() { return true }
            // The first time macOS asks by itself; once answered, only System Settings can change it.
            let asked = UserDefaults.standard.bool(forKey: Self.screenAskedKey)
            UserDefaults.standard.set(true, forKey: Self.screenAskedKey)
            if !CGRequestScreenCaptureAccess(), asked { openSettings() }
            return CGPreflightScreenCaptureAccess()
        case .camera, .microphone:
            let type: AVMediaType = self == .camera ? .video : .audio
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized:
                return true
            case .notDetermined:
                return await AVCaptureDevice.requestAccess(for: type)
            default:
                openSettings()
                return false
            }
        }
    }
}
