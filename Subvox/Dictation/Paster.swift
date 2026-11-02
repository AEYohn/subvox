import AppKit
import ApplicationServices

/// Types text into whatever app is in front: clipboard + ⌘V, then the old clipboard comes back.
/// Posting ⌘V needs Accessibility permission; without it the text is left on the clipboard.
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The user's clipboard while a restore is pending, and the change count of the text we put
    /// there. A second paste before that restore must restore this, not the first dictation.
    private static var pending: (saved: [[NSPasteboard.PasteboardType: Data]], changeCount: Int)?

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns true when the text was pasted, false when it was only copied.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        guard isTrusted else {
            board.clearContents()
            board.setString(text, forType: .string)
            return false
        }
        let saved: [[NSPasteboard.PasteboardType: Data]]
        if let pending, pending.changeCount == board.changeCount {
            // The clipboard still holds our last dictation; the user's own is the one saved then.
            saved = pending.saved
        } else {
            saved = (board.pasteboardItems ?? []).map { item in
                Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } },
                           uniquingKeysWith: { first, _ in first })
            }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount
        pending = (saved, ours)
        postCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Someone copied something in the meantime, or a later paste now owns the restore.
            guard board.changeCount == ours else { return }
            pending = nil
            board.clearContents()
            let items = saved.map { types -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        return true
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
