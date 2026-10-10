import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One recording as it lies on disk, with what the editor needs to know about it.
public struct RecordingProject: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case display, window, area
    }

    public var version = 1
    public var created: Date
    /// Seconds of the recording, pauses taken out.
    public var duration: Double
    public var source: Source
    /// The pixels of screen.mov.
    public var screenSize: CGSize
    public var hasCamera: Bool
    public var hasMicrophone: Bool
    public var hasSystemAudio: Bool
    public var edit: EditSettings
    /// The file name of the last export, in the recording's folder.
    public var lastExport: String?

    public init(created: Date = Date(), duration: Double, source: Source, screenSize: CGSize, hasCamera: Bool,
                hasMicrophone: Bool, hasSystemAudio: Bool, edit: EditSettings = EditSettings()) {
        self.created = created
        self.duration = duration
        self.source = source
        self.screenSize = screenSize
        self.hasCamera = hasCamera
        self.hasMicrophone = hasMicrophone
        self.hasSystemAudio = hasSystemAudio
        self.edit = edit
    }
}

/// The folder of one recording: screen.mov (the screen, then the microphone and the system sound as audio tracks),
/// camera.mov, cursor.json, project.json, a thumbnail and the exported videos. All files share one timeline: zero is
/// the end of the countdown, pauses are taken out.
public struct RecordingFolder: Hashable, Identifiable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var screenURL: URL { url.appendingPathComponent("screen.mov") }
    public var cameraURL: URL { url.appendingPathComponent("camera.mov") }
    public var cursorURL: URL { url.appendingPathComponent("cursor.json") }
    public var projectURL: URL { url.appendingPathComponent("project.json") }
    public var thumbnailURL: URL { url.appendingPathComponent("thumbnail.jpg") }
    /// Where an export goes: the folder's name with .mp4. A new export replaces the old one.
    public var exportURL: URL { url.appendingPathComponent(name + ".mp4") }

    /// A new folder named after the moment, "2026-10-10 14.03.12".
    public static func create(in root: URL, date: Date = Date()) throws -> RecordingFolder {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = format.string(from: date)
        var url = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RecordingFolder(url: url)
    }

    /// The recordings in `root`, the newest first.
    public static func recent(in root: URL, limit: Int = .max) -> [RecordingFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        return urls.map(RecordingFolder.init)
            .filter { FileManager.default.fileExists(atPath: $0.projectURL.path) }
            .sorted { $0.name > $1.name }
            .prefix(limit).map { $0 }
    }

    public func loadProject() throws -> RecordingProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingProject.self, from: Data(contentsOf: projectURL))
    }

    public func save(_ project: RecordingProject) throws {
        try write(project, to: projectURL)
    }

    public func loadCursor() -> CursorTrack {
        (try? JSONDecoder().decode(CursorTrack.self, from: Data(contentsOf: cursorURL))) ?? CursorTrack()
    }

    public func save(_ cursor: CursorTrack) throws {
        try write(cursor, to: cursorURL)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
    }

    /// A small picture for the list of recordings: a frame from the first second, 360 px across at most, as JPEG.
    public func makeThumbnail() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: screenURL))
        generator.maximumSize = CGSize(width: 360, height: 360)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image,
              let target = CGImageDestinationCreateWithURL(thumbnailURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(target)
    }
}
