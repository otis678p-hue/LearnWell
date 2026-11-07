import AppKit
import Foundation

/// Minimal pasteboard writer used by the file shelf and other copy actions.
enum PasteboardPayload {
    case text(String)
    case fileURLs([URL])
}

extension AppModel {
    @discardableResult
    func writeClipboardPayload(_ payload: PasteboardPayload) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch payload {
        case .text(let text):
            return pasteboard.setString(text, forType: .string)
        case .fileURLs(let urls):
            guard !urls.isEmpty else { return false }
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }
}
