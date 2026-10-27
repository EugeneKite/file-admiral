import AppKit

enum Dialogs {
    /// Single-line input dialog. When `selectBaseName` is set, only the part before the extension is selected.
    static func prompt(title: String, message: String, defaultValue: String, selectBaseName: Bool = false,
                       okTitle: String = "OK") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "Cancel")
        let tf = NSTextField(string: defaultValue)
        tf.frame = NSRect(x: 0, y: 0, width: 460, height: 24)
        tf.font = Theme.font
        tf.cell?.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        a.accessoryView = tf
        a.window.initialFirstResponder = tf
        DispatchQueue.main.async {
            guard let editor = tf.currentEditor() else { return }
            let ns = defaultValue as NSString
            if selectBaseName {
                let dot = ns.range(of: ".", options: .backwards)
                let len = (dot.location == NSNotFound || dot.location == 0) ? ns.length : dot.location
                editor.selectedRange = NSRange(location: 0, length: len)
            } else {
                editor.selectedRange = NSRange(location: 0, length: ns.length)
            }
        }
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue : nil
    }

    /// Like `prompt`, with an extra button (e.g. "In Background"). Returns the text and whether the extra button was used.
    static func prompt(title: String, message: String, defaultValue: String, okTitle: String,
                       alternateTitle: String) -> (text: String, alternate: Bool)? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: alternateTitle)
        let tf = NSTextField(string: defaultValue)
        tf.frame = NSRect(x: 0, y: 0, width: 460, height: 24)
        tf.font = Theme.font
        tf.cell?.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        a.accessoryView = tf
        a.window.initialFirstResponder = tf
        switch a.runModal() {
        case .alertFirstButtonReturn: return (tf.stringValue, false)
        case .alertThirdButtonReturn: return (tf.stringValue, true)
        default: return nil
        }
    }

    static func confirm(_ title: String, _ message: String, ok: String = "OK", destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = destructive ? .critical : .warning
        let okButton = a.addButton(withTitle: ok)
        if destructive { okButton.hasDestructiveAction = true }
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func error(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    static func info(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
