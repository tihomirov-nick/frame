import AppKit
import Carbon.HIToolbox
import FrameCore
import SwiftUI

/// A capsule that takes the next key combination as the global shortcut. Esc leaves the old one, ⌫ removes it.
struct ShortcutRecorder: View {
    let key: String
    let defaultValue: Shortcut?

    @State private var shortcut: Shortcut?
    @State private var typing = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { typing ? stop() : start() }) {
                Text(typing ? L("Нажмите сочетание…") : (shortcut?.display ?? L("Не задано")))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(typing || shortcut == nil ? Palette.secondary : .white)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 64)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(typing ? 0.22 : (hovering ? 0.18 : 0.12))))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .onHover { hovering = $0 }
            .help(L("Щёлкните и нажмите новое сочетание. Esc оставляет прежнее, ⌫ удаляет его"))
            if shortcut != defaultValue, !typing, let defaultValue {
                Button {
                    set(defaultValue)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(PressStyle())
                .help(L("Вернуть %@", defaultValue.display))
            }
        }
        .onAppear { shortcut = Shortcut.load(key, default: defaultValue) }
        .onDisappear { stop() }
    }

    private func start() {
        typing = true
        // The current shortcut is let go, so pressing it is taken as the new one instead of starting a recording.
        HotKeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                set(nil)
                stop()
            default:
                if let new = Shortcut(event: event) {
                    set(new)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        guard typing || monitor != nil else { return }
        typing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    private func set(_ value: Shortcut?) {
        shortcut = value
        Shortcut.save(value, for: key)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}
