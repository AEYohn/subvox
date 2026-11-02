import SwiftUI

@main
struct SubvoxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 680)
                .task { model.start() }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            DictationMenu().environment(model)
        } label: {
            Image(systemName: model.dictation.phase == .idle ? "mic" : "mic.fill")
        }
    }
}

private struct DictationMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dictation = model.dictation
        Button(dictation.isEnabled ? "Turn dictation off" : "Turn dictation on") {
            Task { await dictation.setEnabled(!dictation.isEnabled) }
        }
        Text("Hold Right Option to dictate")
        if let last = dictation.history.first, !last.text.isEmpty {
            Divider()
            Text(last.text.count > 60 ? String(last.text.prefix(60)) + "…" : last.text)
        }
        Divider()
        Text("\(model.whisperTakeCount) Whisper-labelled takes")
        Divider()
        Button("Quit Subvox") { NSApp.terminate(nil) }
    }
}
