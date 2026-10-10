import AppKit
import AVFoundation
import FrameCore
import SwiftUI

/// The editor window: the preview with its timeline on the left, the edit and the export on the right.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                PreviewArea(model: model)
                Transport(model: model)
                TrimBar(model: model)
            }
            .padding(EdgeInsets(top: 40, leading: 20, bottom: 20, trailing: 12))
            Inspector(model: model)
                .frame(width: 330)
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .tint(Brand.color)
        .environment(\.colorScheme, .dark)
    }
}

private struct PreviewArea: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let canvas = model.canvas
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Palette.card)
            Group {
                if let poster = model.poster {
                    Image(decorative: poster, scale: 1).resizable()
                } else {
                    PlayerLayerView(player: model.player)
                }
            }
            .aspectRatio(canvas.width / max(canvas.height, 1), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(16)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {}
}

private final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct Transport: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlay) {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help(model.playing ? L("Пауза") : L("Смотреть"))
            Text("\(formatTime(model.time, tenths: true)) / \(formatTime(model.duration, tenths: true))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.secondary)
            Spacer()
            Text(L("В видео %@", formatTime(model.range.upperBound - model.range.lowerBound, tenths: true)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.secondary)
                .help(L("Длина видео после обрезки. Начало и конец обрезаются ручками на шкале"))
        }
    }
}

/// The whole recording as a bar: the trimmed part lit, a handle at each end, a dot at every click, the playhead.
/// A click or a drag on the bar moves the playhead.
private struct TrimBar: View {
    @ObservedObject var model: EditorModel
    private let height: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, duration = max(model.duration, 0.01), range = model.range
            let x = { (t: Double) -> CGFloat in CGFloat(t / duration) * width }
            let time = { (x: CGFloat) -> Double in Double(min(max(x, 0), width) / max(width, 1)) * duration }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.card)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { model.seek(to: time($0.location.x)) })
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(width: max(x(range.upperBound) - x(range.lowerBound), 1), height: height)
                    .offset(x: x(range.lowerBound))
                    .allowsHitTesting(false)
                ForEach(Array(model.clickTimes.enumerated()), id: \.offset) { _, click in
                    Circle()
                        .fill(Color.white.opacity(model.edit.zoom ? 0.85 : 0.3))
                        .frame(width: 5, height: 5)
                        .offset(x: x(click) - 2.5, y: height / 2 - 2.5)
                        .allowsHitTesting(false)
                }
                handle
                    .offset(x: x(range.lowerBound))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { model.setTrim(start: time($0.location.x)) })
                    .help(L("Начало видео"))
                handle
                    .offset(x: x(range.upperBound) - 10)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { model.setTrim(end: time($0.location.x)) })
                    .help(L("Конец видео"))
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height + 8)
                    .offset(x: x(model.time) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: height)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white)
            .frame(width: 10, height: height)
            .overlay(Capsule().fill(Color.black.opacity(0.45)).frame(width: 2, height: 16))
            .contentShape(Rectangle())
    }
}

private struct Inspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                SectionTitle(L("Курсор и приближение"))
                VStack(spacing: 0) {
                    SwitchRow(title: L("Приближать к щелчкам"),
                              help: L("Картинка плавно приближается к месту щелчка и потом отъезжает обратно. Щелчки отмечены точками на шкале"),
                              isOn: $model.edit.zoom)
                    Separator()
                    SwitchRow(title: L("Плавный курсор"),
                              help: L("Курсор скользит без рывков и дрожи руки. Системный курсор в запись не попадает, его рисует монтаж"),
                              isOn: $model.edit.smoothCursor)
                }
                .card()

                SectionTitle(L("Фон"))
                BackgroundPicker(selection: $model.edit.background)
                    .padding(10)
                    .card()

                SectionTitle(L("Рамка"))
                VStack(spacing: 0) {
                    SliderRow(title: L("Поля"), help: L("Отступ от края кадра до записи"), value: $model.edit.padding, range: 0...0.16)
                    Separator()
                    SliderRow(title: L("Скругление"), help: L("Радиус углов записи"), value: $model.edit.cornerRadius, range: 0...0.06)
                    Separator()
                    SwitchRow(title: L("Тень"), help: L("Мягкая тень под записью"), isOn: $model.edit.shadow)
                }
                .card()

                if model.project.hasCamera {
                    SectionTitle(L("Камера"))
                    VStack(spacing: 0) {
                        SwitchRow(title: L("Показывать камеру"), help: L("Круглый пузырь с камерой поверх видео"),
                                  isOn: $model.edit.cameraVisible)
                        Separator()
                        Row(title: L("Угол"), help: L("В каком углу кадра стоит пузырь")) {
                            MenuCapsule(title: model.edit.cameraCorner.title, help: L("Угол"), makeMenu: cornerMenu)
                        }
                        Separator()
                        SliderRow(title: L("Размер"), help: L("Диаметр пузыря"), value: $model.edit.cameraSize, range: 0.14...0.4)
                    }
                    .card()
                }

                SectionTitle(L("Экспорт"))
                ExportCard(model: model)
            }
            .padding(EdgeInsets(top: 40, leading: 8, bottom: 16, trailing: 16))
        }
        .scrollIndicators(.never)
    }

    private func cornerMenu() -> NSMenu {
        let menu = NSMenu()
        for corner in [EditSettings.Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            menu.addItem(ClosureMenuItem(corner.title, checked: corner == model.edit.cameraCorner) { model.edit.cameraCorner = corner })
        }
        return menu
    }
}

private struct SliderRow: View {
    let title: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Row(title: title, help: help) {
            Slider(value: $value, in: range)
                .controlSize(.small)
                .frame(width: 150)
        }
    }
}

private struct BackgroundPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(BackgroundPreset.all) { preset in
                let chosen = preset.id == selection
                Button { selection = preset.id } label: {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill(preset))
                        .frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(chosen ? 1 : 0.14), lineWidth: chosen ? 2 : 1))
                }
                .buttonStyle(PressStyle())
                .help(preset.title)
                .accessibilityLabel(preset.title)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    private func fill(_ preset: BackgroundPreset) -> AnyShapeStyle {
        let colors = preset.colors.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
        guard colors.count > 1 else { return AnyShapeStyle(colors[0]) }
        return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

private struct ExportCard: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            Row(title: L("Кодек"), help: L("H.264 открывается везде. С HEVC файл примерно вдвое меньше, его понимают устройства последних лет")) {
                MenuCapsule(title: model.options.codec.title, help: L("Кодек")) {
                    let menu = NSMenu()
                    for codec in ExportOptions.Codec.allCases {
                        menu.addItem(ClosureMenuItem(codec.title, checked: codec == model.options.codec) { model.options.codec = codec })
                    }
                    return menu
                }
            }
            Separator()
            Row(title: L("Размер кадра"), help: L("1080p: кадр 1920 × 1080, запись вписана в него. «Как у записи»: кадр размером с записанный экран")) {
                MenuCapsule(title: model.options.resolution.title, help: L("Размер кадра")) {
                    let menu = NSMenu()
                    for resolution in ExportOptions.Resolution.allCases {
                        menu.addItem(ClosureMenuItem(resolution.title, checked: resolution == model.options.resolution) {
                            model.options.resolution = resolution
                        })
                    }
                    return menu
                }
            }
            Separator()
            action
                .padding(12)
        }
        .card()
    }

    @ViewBuilder private var action: some View {
        switch model.exportState {
        case .running(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text("\(Int(progress * 100)) %")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 38, alignment: .trailing)
                Button(L("Прервать")) { model.cancelExport() }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
            }
        case .done(let url):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        model.export()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.secondary)
                    }
                    .buttonStyle(PressStyle())
                    .help(L("Экспортировать заново с новыми настройками"))
                }
                HStack(spacing: 8) {
                    Button(L("Показать в Finder")) { model.revealExport() }
                        .appButton(.primary)
                        .fixedSize()
                    Button(L("Скопировать файл")) { model.copyExport() }
                        .appButton(.secondary)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let message) = model.exportState {
                    Text(L("Экспорт не получился: %@", message))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    model.export()
                } label: {
                    Text(L("Экспортировать в MP4")).frame(maxWidth: .infinity)
                }
                .appButton(.primary)
                Text(L("Файл появится в папке записи. Видео собирается на этом Mac, в интернет ничего не уходит"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }
}

extension EditSettings.Corner {
    var title: String {
        switch self {
        case .topLeft: return L("Слева вверху")
        case .topRight: return L("Справа вверху")
        case .bottomLeft: return L("Слева внизу")
        case .bottomRight: return L("Справа внизу")
        }
    }
}

extension ExportOptions.Codec {
    var title: String { self == .h264 ? "H.264" : "HEVC" }
}

extension ExportOptions.Resolution {
    var title: String { self == .p1080 ? "1080p" : L("Как у записи") }
}

extension BackgroundPreset {
    var title: String {
        switch id {
        case "ocean": return L("Океан")
        case "dusk": return L("Закат")
        case "lavender": return L("Лаванда")
        case "mint": return L("Мята")
        case "peach": return L("Персик")
        case "night": return L("Ночь")
        case "snow": return L("Светлый")
        case "graphite": return L("Графит")
        case "black": return L("Чёрный")
        default: return L("Синий")
        }
    }
}
