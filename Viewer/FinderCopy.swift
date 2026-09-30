import Cocoa

/// ⌘C in the Space panel as Finder's: one pasteboard item carrying the file and its text, so Finder pastes the file and an
/// editor the text.
enum FinderCopy {
    static func write(file url: URL, text: String, to pb: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        guard url.isFileURL, item.setString(url.absoluteString, forType: .fileURL), item.setString(text, forType: .string) else { return false }
        pb.clearContents()
        return pb.writeObjects([item])
    }
}
