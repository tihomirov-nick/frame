import AppKit
import FrameCore

/// The app's own settings in UserDefaults; the switches of the panel read them with @AppStorage.
enum Preferences {
    enum Mode: String, CaseIterable {
        case display, window, area
    }

    static let modeKey = "captureMode"
    static let cameraKey = "camera"
    static let microphoneKey = "microphone"
    static let systemAudioKey = "systemAudio"
    static let shortcutKey = "recordShortcut"
    static let bubbleCornerKey = "bubbleCorner"
    static let exportKey = "exportOptions"
    private static let folderKey = "recordingsFolder"
    private static let editKey = "lastEdit"

    private static var defaults: UserDefaults { .standard }

    static var mode: Mode {
        get { defaults.string(forKey: modeKey).flatMap(Mode.init) ?? .display }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    static var camera: Bool { defaults.object(forKey: cameraKey) as? Bool ?? true }
    static var microphone: Bool { defaults.object(forKey: microphoneKey) as? Bool ?? true }
    static var systemAudio: Bool { defaults.object(forKey: systemAudioKey) as? Bool ?? false }

    /// ~/Movies/<name>.
    static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppName.value, isDirectory: true)
    }

    /// The preview pictures put their made-up recordings elsewhere and save nothing.
    static var folderOverride: URL?

    /// Where recordings go. Nil resets it to the default.
    static var folder: URL {
        folderOverride ?? defaults.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
    }

    static func setFolder(_ url: URL?) {
        defaults.set(url?.path, forKey: folderKey)
    }

    static func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    static var bubbleCorner: EditSettings.Corner {
        get { defaults.string(forKey: bubbleCornerKey).flatMap(EditSettings.Corner.init) ?? .bottomLeft }
        set { defaults.set(newValue.rawValue, forKey: bubbleCornerKey) }
    }

    /// The edit a new recording starts with: the look of the last edit, without its trim.
    static var lastEdit: EditSettings {
        get {
            var edit = defaults.data(forKey: editKey).flatMap { try? JSONDecoder().decode(EditSettings.self, from: $0) }
                ?? EditSettings()
            edit.trimStart = 0
            edit.trimEnd = nil
            return edit
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: editKey) }
    }

    static var exportOptions: ExportOptions {
        get { defaults.data(forKey: exportKey).flatMap { try? JSONDecoder().decode(ExportOptions.self, from: $0) } ?? ExportOptions() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: exportKey) }
    }
}
