import AppKit
import SwiftUI

/// An actual text document fills the viewport, so clicking whitespace also focuses
/// the response and enables the standard select-all/copy keyboard commands.
struct ResponseTextEditor: NSViewRepresentable {
    let text: String
    var jsonRows: [JSONResponseRow] = []
    var isFailure = false
    var onToggleNode: ((Int) -> Void)?
    var onCopyNode: ((Int) -> Void)?

    func makeNSView(context: Context) -> ResponseEditorContainer {
        let editor = ResponseEditorContainer()
        let scrollView = editor.scrollView
        let textView = ResponseEditorTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = scrollView.contentSize
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = textView.maxSize
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        editor.gutter.textView = textView
        return editor
    }

    func updateNSView(_ editor: ResponseEditorContainer, context: Context) {
        let scrollView = editor.scrollView
        guard let textView = scrollView.documentView as? ResponseEditorTextView else { return }
        textView.onToggleNode = onToggleNode
        textView.onCopyNode = onCopyNode
        let signature = RenderSignature(text: text, rows: jsonRows, isFailure: isFailure)
        guard context.coordinator.signature != signature else { return }
        let sourceChanged = context.coordinator.signature?.text != text
        let structureChanged = context.coordinator.signature?.rows != jsonRows
        context.coordinator.signature = signature
        let selected = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        textView.rows = jsonRows
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textStorage?.setAttributedString(renderedText())
        textView.refreshLineStarts()
        editor.showsGutter = !jsonRows.isEmpty
        editor.layoutSubtreeIfNeeded()
        textView.sizeToFit()
        scrollView.resizeDocumentToViewport()
        if sourceChanged {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollView.contentView.scroll(to: .zero)
        } else {
            if structureChanged {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                let length = textView.string.utf16.count
                let location = min(selected.location, length)
                textView.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
            }
            scrollView.contentView.scroll(to: origin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.needsDisplay = true
        scrollView.refreshGutter()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var signature: RenderSignature?
    }

    struct RenderSignature: Equatable {
        let text: String
        let rows: [JSONResponseRow]
        let isFailure: Bool
    }

    private func renderedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: isFailure ? NSColor.systemRed : NSColor.textColor,
            .paragraphStyle: paragraph
        ]
        guard !jsonRows.isEmpty else { return NSAttributedString(string: text, attributes: attributes) }
        let output = NSMutableAttributedString(string: "")
        for (index, row) in jsonRows.enumerated() {
            func append(_ value: String, color: NSColor) {
                var style = attributes
                style[.foregroundColor] = color
                output.append(NSAttributedString(string: value, attributes: style))
            }
            append(String(repeating: "  ", count: row.depth), color: .textColor)
            if let key = row.key {
                append(key, color: .systemBlue)
                append(": ", color: .secondaryLabelColor)
            }
            let color: NSColor
            switch row.kind {
            case .string: color = .systemGreen
            case .number: color = .systemOrange
            case .bool: color = .systemPurple
            case .null: color = .secondaryLabelColor
            case .object, .array: color = .textColor
            }
            append(row.value, color: color)
            if row.hasComma { append(",", color: .secondaryLabelColor) }
            if row.isCollapsed {
                append("  // \(row.childCount) \(row.kind == .array ? "items" : "keys")", color: .tertiaryLabelColor)
            }
            if index != jsonRows.count - 1 { append("\n", color: .textColor) }
        }
        return output
    }
}

final class ResponseEditorContainer: NSView {
    let scrollView = ResponseEditorScrollView()
    let gutter = ResponseEditorGutter()
    var showsGutter = false {
        didSet {
            gutter.isHidden = !showsGutter
            needsLayout = true
        }
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(scrollView)
        addSubview(gutter)
        gutter.isHidden = true
        scrollView.gutter = gutter
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width: CGFloat = showsGutter ? 78 : 0
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        scrollView.resizeDocumentToViewport()
        gutter.refresh()
    }
}

final class ResponseEditorScrollView: NSScrollView {
    weak var gutter: ResponseEditorGutter?
    override func tile() {
        super.tile()
        resizeDocumentToViewport()
        refreshGutter()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        refreshGutter()
    }

    func refreshGutter() {
        guard let gutter, !gutter.isHidden else { return }
        gutter.refresh()
    }

    func resizeDocumentToViewport() {
        guard let textView = documentView as? NSTextView else { return }
        let viewport = contentSize
        textView.minSize = viewport
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let inset = textView.textContainerInset
        let fitted = NSSize(width: max(viewport.width, ceil(used.maxX) + inset.width * 2),
                            height: max(viewport.height, ceil(used.maxY) + inset.height * 2))
        if textView.frame.size != fitted { textView.setFrameSize(fitted) }
    }
}

final class ResponseEditorTextView: NSTextView {
    var rows: [JSONResponseRow] = []
    var onToggleNode: ((Int) -> Void)?
    var onCopyNode: ((Int) -> Void)?
    private var lineStarts = [0]

    func refreshLineStarts() {
        lineStarts = [0]
        for (index, character) in string.utf16.enumerated() where character == 10 {
            lineStarts.append(index + 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let index = rowIndex(at: convert(event.locationInWindow, from: nil)) {
            let item = NSMenuItem(title: "复制此节点 JSON", action: #selector(copyJSONNode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rows[index].nodeID
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func copyJSONNode(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? Int { onCopyNode?(id) }
    }

    func visibleJSONLines() -> [(index: Int, rect: NSRect)] {
        guard !rows.isEmpty, let manager = layoutManager, let container = textContainer else { return [] }
        let visible = visibleRect
        let layoutRect = NSRect(x: 0, y: max(0, visible.minY - textContainerOrigin.y),
                                width: max(1, bounds.width), height: visible.height)
        let glyphs = manager.glyphRange(forBoundingRect: layoutRect, in: container)
        guard glyphs.length > 0 else { return [] }
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var result: [(index: Int, rect: NSRect)] = []
        for index in rows.indices {
            guard lineStarts.indices.contains(index) else { break }
            let start = lineStarts[index]
            guard start >= characters.location || (index + 1 < lineStarts.count && lineStarts[index + 1] > characters.location) else { continue }
            guard start <= NSMaxRange(characters) else { break }
            let glyph = manager.glyphIndexForCharacter(at: start)
            guard glyph < manager.numberOfGlyphs else { continue }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            if line.intersects(visible) { result.append((index, line)) }
        }
        return result
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        guard !rows.isEmpty, let manager = layoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: max(0, point.x - textContainerOrigin.x), y: point.y - textContainerOrigin.y)
        guard local.y >= 0 else { return nil }
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= line.minY, local.y < line.maxY else { return nil }
        let character = manager.characterIndexForGlyph(at: glyph)
        let index = lineStarts.lastIndex { $0 <= character } ?? 0
        return rows.indices.contains(index) ? index : nil
    }
}

/// Separate from the scrolling text viewport, so the operation area stays fixed.
/// Only visible rows get actual native buttons.
final class ResponseEditorGutter: NSView {
    weak var textView: ResponseEditorTextView?
    private var buttons: [Int: NSButton] = [:]
    private var visibleLines: [(index: Int, rect: NSRect)] = []
    override var isFlipped: Bool { true }

    func refresh() {
        guard let textView else { return }
        visibleLines = textView.visibleJSONLines().map { entry in
            (entry.index, convert(entry.rect, from: textView))
        }
        var visibleIDs: Set<Int> = []
        for entry in visibleLines {
            let row = textView.rows[entry.index]
            guard row.isExpandable, !row.isClosing else { continue }
            visibleIDs.insert(row.nodeID)
            let button: NSButton
            if let existing = buttons[row.nodeID] {
                button = existing
            } else {
                button = NSButton(title: "", target: self, action: #selector(toggleNode(_:)))
                button.setButtonType(.momentaryPushIn)
                button.bezelStyle = .smallSquare
                button.controlSize = .small
                button.isBordered = true
                button.imagePosition = .imageOnly
                button.contentTintColor = .systemOrange
                buttons[row.nodeID] = button
                addSubview(button)
            }
            let title = row.isCollapsed ? "展开节点" : "折叠节点"
            button.tag = row.nodeID
            button.image = NSImage(systemSymbolName: row.isCollapsed ? "chevron.right" : "chevron.down",
                                   accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            button.toolTip = "\(title) · \(row.childCount) \(row.kind == .array ? "项" : "个字段")"
            button.setAccessibilityLabel(title)
            button.frame = NSRect(x: 50, y: floor(entry.rect.midY - 9), width: 18, height: 18)
        }
        for id in Array(buttons.keys) where !visibleIDs.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        needsDisplay = true
    }

    @objc private func toggleNode(_ sender: NSButton) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.onToggleNode?(sender.tag)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.16, alpha: 1)
                : NSColor(calibratedWhite: 0.95, alpha: 1)
        }
        background.setFill()
        bounds.fill()
        let divider = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.32, alpha: 1)
                : NSColor(calibratedWhite: 0.80, alpha: 1)
        }
        divider.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        for entry in visibleLines {
            let number = NSAttributedString(string: "\(entry.index + 1)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            number.draw(at: NSPoint(x: 40 - number.size().width, y: entry.rect.minY + 1))
        }
    }
}
