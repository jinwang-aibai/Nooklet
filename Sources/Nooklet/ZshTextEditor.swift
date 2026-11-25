import AppKit
import SwiftUI

struct ZshTextEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        scroll.borderType = .noBorder
        scroll.backgroundColor = NSColor(WorkspaceTerminal.background)
        scroll.scrollerKnobStyle = .light
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.backgroundColor = NSColor(WorkspaceTerminal.background)
        editor.textColor = NSColor(WorkspaceTerminal.foreground)
        editor.insertionPointColor = NSColor(WorkspaceTerminal.accent)
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor(WorkspaceTerminal.selection),
            .foregroundColor: NSColor.white,
        ]
        editor.textContainerInset = NSSize(width: 7, height: 9)
        editor.setAccessibilityLabel(L10n.text("配置文件内容"))

        let ruler = ZshLineNumbers(scrollView: scroll)
        ruler.editor = editor
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = ruler
        scroll.rulersVisible = true
        context.coordinator.ruler = ruler
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = view.documentView as? NSTextView else { return }
        editor.isEditable = editable
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
            context.coordinator.updatePresentation(of: editor, immediately: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        fileprivate weak var ruler: ZshLineNumbers?
        private var highlightTask: Task<Void, Never>?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
            updatePresentation(of: editor, immediately: false)
        }

        func updatePresentation(of editor: NSTextView, immediately: Bool) {
            ruler?.updateLines(editor.string as NSString)
            highlightTask?.cancel()
            if immediately {
                ZshSyntax.highlight(editor)
            } else {
                highlightTask = Task { [weak editor] in
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                    if let editor { ZshSyntax.highlight(editor) }
                }
            }
        }
    }
}

@MainActor
private final class ZshLineNumbers: NSRulerView {
    weak var editor: NSTextView?
    private var lineStarts = [0]

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 37
    }

    required init(coder: NSCoder) { fatalError("Use init(scrollView:)") }

    override var isFlipped: Bool { true }

    func updateLines(_ text: NSString) {
        lineStarts = [0]
        var cursor = 0
        while cursor < text.length {
            var end = 0
            var contentEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            if end > contentEnd { lineStarts.append(end) }
            cursor = end
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(WorkspaceTerminal.header).setFill()
        bounds.fill()
        NSColor(WorkspaceTerminal.subdued).withAlphaComponent(0.18).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }

        let origin = convert(editor.textContainerOrigin, from: editor)
        let inset = editor.textContainerOrigin
        let visible = editor.visibleRect.offsetBy(dx: -inset.x, dy: -inset.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            let index = self.lineIndex(containing: character)
            if self.lineStarts[index] == character {
                self.drawNumber(index + 1, at: origin.y + fragment.minY)
            }
        }
        if editor.string.isEmpty {
            drawNumber(1, at: origin.y)
        } else if lineStarts.last == editor.textStorage?.length, layout.extraLineFragmentTextContainer === container {
            drawNumber(lineStarts.count, at: origin.y + layout.extraLineFragmentRect.minY)
        }
    }

    private func lineIndex(containing character: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= character { lower = middle } else { upper = middle }
        }
        return lower
    }

    private func drawNumber(_ number: Int, at y: CGFloat) {
        let number = NSAttributedString(string: String(number), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(WorkspaceTerminal.subdued),
        ])
        number.draw(at: NSPoint(x: bounds.maxX - 7 - number.size().width, y: y + 1))
    }
}

@MainActor
private enum ZshSyntax {
    private static let tokens = try! NSRegularExpression(pattern: #"""
    (?mx)
    (?<comment>(?<![A-Za-z0-9_$\\])\x23[^\r\n]*)
    | (?<literal>'[^']*')
    | (?<quoted>"(?:\\[\s\S]|[^"\\])*")
    | (?<variable>\$(?:\{[^}\r\n]+\}|[A-Za-z_][A-Za-z_0-9]*|[0-9@*?\x23$!]))
    | (?<keyword>\b(?:export|source|alias|unalias|if|then|else|elif|fi|for|while|in|do|done|function|local|typeset|unset|return|case|esac|autoload|setopt|unsetopt|eval|echo|printf|test)\b)
    | (?<option>(?<![\w-])--?[A-Za-z][A-Za-z0-9-]*)
    | (?<number>(?<![\w./-])\d+(?![\w./-]))
    """#)
    private static let variables = try! NSRegularExpression(pattern: #"""
    (?<!\\)\$(?:\{[^}\r\n]+\}|[A-Za-z_][A-Za-z_0-9]*|[0-9@*?\x23$!])
    """#)

    private static let roles: [(String, NSColor)] = [
        ("comment", NSColor(WorkspaceTerminal.subdued)),
        ("literal", NSColor(WorkspaceTerminal.literal)),
        ("quoted", NSColor(WorkspaceTerminal.literal)),
        ("variable", NSColor(WorkspaceTerminal.accent)),
        ("keyword", NSColor(WorkspaceTerminal.keyword)),
        ("option", NSColor(WorkspaceTerminal.option)),
        ("number", NSColor(WorkspaceTerminal.option)),
    ]

    static func highlight(_ editor: NSTextView) {
        guard let layout = editor.layoutManager, let storage = editor.textStorage else { return }
        let text = editor.string
        let whole = NSRange(location: 0, length: storage.length)
        guard whole.length > 0 else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        tokens.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            for (role, color) in roles {
                let range = match.range(withName: role)
                guard range.location != NSNotFound else { continue }
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
                if role == "quoted" {
                    variables.enumerateMatches(in: text, range: range) { variable, _, _ in
                        if let variable {
                            layout.addTemporaryAttribute(.foregroundColor, value: NSColor(WorkspaceTerminal.accent),
                                                         forCharacterRange: variable.range)
                        }
                    }
                }
                break
            }
        }
    }
}
