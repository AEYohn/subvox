import AppKit
import SwiftUI

/// The small floating pill at the bottom of the screen while you dictate, like Wispr Flow's.
@MainActor
final class DictationHUD {
    enum State { case listening, transcribing }

    @Observable
    final class Model {
        var state: State = .listening
    }

    private let model = Model()
    private var panel: NSPanel?
    private weak var audio: AudioService?

    init(audio: AudioService?) {
        self.audio = audio
    }

    func show(_ state: State) {
        model.state = state
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model, audio: audio))
        return panel
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 28))
    }
}

private struct HUDView: View {
    var model: DictationHUD.Model
    var audio: AudioService?

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .listening:
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelBars(level: CGFloat(audio?.level ?? 0))
                Text("Listening").font(.callout.weight(.medium))
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing").font(.callout.weight(.medium))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: 190, height: 40)
        .background(Capsule().fill(.black.opacity(0.82)))
    }
}

private struct LevelBars: View {
    var level: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let weight: CGFloat = [0.5, 0.8, 1, 0.8, 0.5][i]
                Capsule().fill(.white)
                    .frame(width: 3, height: max(4, 18 * level * weight))
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }
}
