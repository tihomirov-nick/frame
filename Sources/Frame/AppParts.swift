import AppKit
import FrameCore
import SwiftUI

// The places where an app made from the template becomes itself. The rest of Sources/Frame is the family's
// plumbing: the icon with its menu and panel, Settings, updates, the interface language and the sounds. The recorder
// itself is in Recording/ and Editor/, the edit and the export in FrameCore/Engine.

// MARK: - 1. The glyph

extension MenuBarIcon {
    /// While a recording runs the bubble of the glyph, which is also the record dot, becomes a square, as on a «Стоп»
    /// button. That is the icon's only change: nothing moves or fades.
    static var recording = false

    /// The screen frame with the camera bubble. The drawing is the family's glyph file (Glyph.swift, Frame.swift) and
    /// sets its own size (16 pt tall) and lines, so the template's `box` is not used; scripts/make_icon.sh draws the
    /// same mark large (`drawMark`).
    static func drawGlyph(in ctx: CGContext, box: CGRect) {
        ctx.saveGState()
        Glyph.enterMenuBox(ctx, bounds: Frame.bounds, scale: max(1, abs(ctx.ctm.a)))
        Frame.draw(ctx, recording: recording, line: Glyph.menuLine, gap: Glyph.menuGap)
        ctx.restoreGState()
    }
}

// MARK: - 2. The main view

/// The panel under the icon: what to record and with what, «Начать запись», the controls while recording, the last
/// recordings.
struct MainView: View {
    @ObservedObject private var recorder = RecordingController.shared
    @ObservedObject private var recent = RecentStore.shared
    @State private var screenAllowed = Permission.screen.granted

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if recorder.isActive {
                RecordingCard(recorder: recorder)
            } else {
                ModePicker()
                SourceSwitches()
                if !screenAllowed {
                    NoticeCard(text: L("Для записи экрана нужно разрешение macOS"),
                               button: L("Разрешить")) {
                        Task { screenAllowed = await Permission.screen.request() }
                    }
                }
                Button {
                    recorder.start()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                        Text(L("Начать запись"))
                        Spacer(minLength: 4)
                        if let shortcut = Shortcut.load(Preferences.shortcutKey, default: Shortcut.recordDefault) {
                            Text(shortcut.display).opacity(0.55)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .appButton(.primary)
            }
            RecentList(store: recent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            recent.reload()
            screenAllowed = Permission.screen.granted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAllowed = Permission.screen.granted
        }
    }
}

/// Экран, Окно or Область: three tiles.
private struct ModePicker: View {
    @AppStorage(Preferences.modeKey) private var mode = Preferences.Mode.display.rawValue

    var body: some View {
        HStack(spacing: 6) {
            tile(.display, symbol: "display", title: L("Экран"), help: L("Весь экран, на котором сейчас курсор"))
            tile(.window, symbol: "macwindow", title: L("Окно"), help: L("Одно окно: его выбирают в меню после нажатия «Начать запись»"))
            tile(.area, symbol: "rectangle.dashed", title: L("Область"), help: L("Часть экрана: её выделяют мышью после нажатия «Начать запись»"))
        }
    }

    private func tile(_ value: Preferences.Mode, symbol: String, title: String, help: String) -> some View {
        let chosen = mode == value.rawValue
        return Button {
            mode = value.rawValue
            Haptics.tap()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(chosen ? 0.16 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(chosen ? 0.55 : 0), lineWidth: 1))
            .foregroundStyle(chosen ? Color.white : Palette.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The camera, the microphone and the sound of the Mac, each switched on and off with a click.
private struct SourceSwitches: View {
    @AppStorage(Preferences.cameraKey) private var camera = true
    @AppStorage(Preferences.microphoneKey) private var microphone = true
    @AppStorage(Preferences.systemAudioKey) private var systemAudio = false

    var body: some View {
        HStack(spacing: 6) {
            chip($camera, on: "video.fill", off: "video.slash.fill", title: L("Камера"),
                 help: L("Круглый пузырь с камерой поверх экрана. В монтаже его можно передвинуть или убрать"))
            chip($microphone, on: "mic.fill", off: "mic.slash.fill", title: L("Микрофон"),
                 help: L("Ваш голос в записи"))
            chip($systemAudio, on: "speaker.wave.2.fill", off: "speaker.slash.fill", title: L("Звук Mac"),
                 help: L("Звук приложений и роликов, которые играют во время записи"))
        }
    }

    private func chip(_ isOn: Binding<Bool>, on: String, off: String, title: String, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn.wrappedValue ? on : off).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(isOn.wrappedValue ? 0.16 : 0.06)))
            .foregroundStyle(isOn.wrappedValue ? Color.white : Palette.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? L("Включено") : L("Выключено"))
    }
}

/// The recording in progress: the time and the same three buttons as the panel at the bottom of the screen.
private struct RecordingCard: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(recorder.paused ? Palette.secondary : Color.red).frame(width: 9, height: 9)
                Text(status).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formatTime(recorder.elapsed))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            HStack(spacing: 6) {
                Button(recorder.paused ? L("Продолжить") : L("Пауза")) { recorder.togglePause() }
                    .appButton(.secondary)
                    .disabled(recorder.phase != .recording)
                Button(L("Стоп")) { recorder.stop() }
                    .appButton(.primary)
                    .disabled(recorder.phase == .finishing)
                Spacer(minLength: 0)
                Button {
                    recorder.cancel()
                } label: {
                    Image(systemName: "trash")
                }
                .appButton(.secondary)
                .help(L("Отменить запись: файл не сохранится"))
                .accessibilityLabel(L("Отменить запись"))
                .disabled(recorder.phase == .finishing)
            }
            .controlSize(.small)
        }
        .padding(12)
        .card()
    }

    private var status: String {
        switch recorder.phase {
        case .preparing: return L("Готовимся…")
        case .countdown: return L("Сейчас начнётся")
        case .finishing: return L("Сохраняем запись…")
        default: return recorder.paused ? L("Пауза") : L("Идёт запись")
        }
    }
}

/// A note with a button, on a card.
private struct NoticeCard: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action)
                .appButton(.secondary)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(12)
        .card()
    }
}

/// The last recordings, the newest first: a click opens the editor.
private struct RecentList: View {
    @ObservedObject var store: RecentStore

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            SectionTitle(L("Последние записи"))
            if store.items.isEmpty {
                Text(L("Записей пока нет. Они будут здесь и в папке «%@»", Preferences.folder.lastPathComponent))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Separator(leading: 68) }
                        RecentRow(item: item)
                    }
                }
                .card()
            }
            Button(L("Открыть папку с записями")) { Preferences.revealFolder() }
                .appButton(.secondary)
                .controlSize(.small)
        }
    }
}

private struct RecentRow: View {
    let item: RecentStore.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").foregroundStyle(Palette.secondary)
                }
            }
            .frame(width: 48, height: 30)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.05 : 0))
            .padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            StatusItem.shared.hidePanel()
            EditorWindows.show(item.folder)
        }
        .help(L("Открыть в монтаже"))
    }
}

/// The recordings of the folder from Settings, read again when the panel opens and after a recording or an export.
@MainActor
final class RecentStore: ObservableObject {
    static let shared = RecentStore()

    struct Item: Identifiable {
        let folder: RecordingFolder
        let date: Date
        let duration: Double
        let exported: Bool
        let thumbnail: NSImage?

        var id: URL { folder.url }

        var title: String {
            date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: Localization.current)))
        }

        var subtitle: String {
            exported ? L("%@, видео готово", formatTime(duration)) : formatTime(duration)
        }
    }

    @Published private(set) var items: [Item] = []

    func reload() {
        items = RecordingFolder.recent(in: Preferences.folder, limit: 4).compactMap { folder in
            guard let project = try? folder.loadProject() else { return nil }
            return Item(folder: folder, date: project.created, duration: project.duration,
                        exported: FileManager.default.fileExists(atPath: folder.exportURL.path),
                        thumbnail: NSImage(contentsOf: folder.thumbnailURL))
        }
    }
}

// MARK: - 3. The app's section in Settings

/// «Запись»: the folder and the shortcut; «Разрешения»: the screen, the camera and the microphone.
struct AppSettingsSection: View {
    var body: some View {
        SectionTitle(L("Запись"))
        VStack(spacing: 0) {
            FolderRow()
            Separator()
            Row(title: L("Сочетание клавиш"),
                help: L("Начинает и останавливает запись из любого приложения. Что записывать, выбирается в окошке значка")) {
                ShortcutRecorder(key: Preferences.shortcutKey, defaultValue: Shortcut.recordDefault)
            }
        }
        .card()

        SectionTitle(L("Разрешения"))
        VStack(spacing: 0) {
            ForEach(Array(Permission.allCases.enumerated()), id: \.offset) { index, permission in
                if index > 0 { Separator() }
                PermissionRow(permission: permission)
            }
        }
        .card()
    }
}

private struct FolderRow: View {
    @State private var folder = Preferences.folder

    var body: some View {
        Row(title: L("Папка для записей"), help: folder.path) {
            MenuCapsule(title: folder.lastPathComponent, help: L("Папка для записей"), makeMenu: menu)
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Выбрать другую папку…")) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = folder
            NSApp.activate()
            if panel.runModal() == .OK, let url = panel.url {
                Preferences.setFolder(url)
                refresh()
            }
        })
        menu.addItem(ClosureMenuItem(L("Показать в Finder")) { Preferences.revealFolder() })
        if folder != Preferences.defaultFolder {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Вернуть папку «%@»", Preferences.defaultFolder.lastPathComponent)) {
                Preferences.setFolder(nil)
                refresh()
            })
        }
        return menu
    }

    private func refresh() {
        folder = Preferences.folder
        RecentStore.shared.reload()
    }
}

private struct PermissionRow: View {
    let permission: Permission
    @State private var granted = false

    var body: some View {
        Row(title: permission.title, help: permission.help) {
            if granted {
                Text(L("Разрешено"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            } else {
                Button(L("Разрешить")) {
                    Task { granted = await permission.request() }
                }
                .appButton(.secondary)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .onAppear { granted = permission.granted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = permission.granted
        }
    }
}

// MARK: - 4. The actions of the menu and 5. being busy

@MainActor
enum AppActions {
    /// Start a recording of each kind, or control the one in progress; then the folder.
    static func menuItems() -> [NSMenuItem] {
        let recorder = RecordingController.shared
        if recorder.isActive {
            var items: [NSMenuItem] = [ClosureMenuItem(L("Остановить запись")) { recorder.stop() }]
            if recorder.phase == .recording {
                items.append(ClosureMenuItem(recorder.paused ? L("Продолжить запись") : L("Поставить запись на паузу")) {
                    recorder.togglePause()
                })
            }
            items.append(ClosureMenuItem(L("Отменить запись")) { recorder.cancel() })
            return items
        }
        return [
            ClosureMenuItem(L("Записать экран")) { recorder.start(.display) },
            ClosureMenuItem(L("Записать окно…")) { recorder.start(.window) },
            ClosureMenuItem(L("Записать область…")) { recorder.start(.area) },
            ClosureMenuItem(L("Открыть папку с записями")) { Preferences.revealFolder() },
        ]
    }

    /// A recording or an export in progress.
    static var isBusy: Bool {
        RecordingController.shared.isActive || EditorWindows.isExporting
    }

    /// At launch (from AppDelegate): the shortcut.
    static func didFinishLaunching() {
        RecordShortcut.install()
    }

    /// Quitting during a recording saves it first; an export in progress stops.
    static func shouldTerminate() -> NSApplication.TerminateReply {
        guard isBusy else { return .terminateNow }
        Task {
            EditorWindows.cancelExports()
            await RecordingController.shared.finishBeforeQuit()
            while EditorWindows.isExporting { try? await Task.sleep(nanoseconds: 50_000_000) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
