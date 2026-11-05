import AppKit
import ApplicationServices

/// Types the text into the frontmost app by pasting it, then puts back what the clipboard
/// held before.
@MainActor
enum Paster {
    /// Sending Cmd+V to another app needs Accessibility. Without it the text stays on the
    /// clipboard and the paste is left to the user.
    static func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return false }

        // The flags are set outright, so an Option or Shift still held from the shortcut
        // doesn't turn this into Paste and Match Style or a move in Finder.
        let source = CGEventSource(stateID: .privateState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        // The target app reads the clipboard when it handles the event, which can take a
        // moment; restoring sooner would paste the old contents.
        try? await Task.sleep(for: .milliseconds(500))
        if pasteboard.string(forType: .string) == text {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return true
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// Shows macOS's prompt that leads to the Accessibility list.
    static func askForAccess() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read from a global.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
