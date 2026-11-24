import AppKit

@MainActor
final class CaptureToolbar: NSView {
    enum Command {
        case select(MarkTool?), color(NSColor), size(Int)
        case undo, redo, reselect, finish(CaptureAction), cancel
    }

    private static let palette: [(NSColor, String)] = [
        (.systemRed, "红色"), (.systemOrange, "橙色"), (.systemYellow, "黄色"),
        (.systemGreen, "绿色"), (.systemBlue, "蓝色"), (.white, "白色"), (.black, "黑色")
    ]

    private let bar = CaptureToolbarSurface()
    private let options = CaptureToolbarSurface()
    private var groups: [[CaptureToolbarButton]] = []
    private var toolButtons: [MarkTool: CaptureToolbarButton] = [:]
    private var colorButtons: [CaptureToolbarButton] = []
    private var sizeButtons: [CaptureToolbarButton] = []
    private var dividers: [NSView] = []
    private let optionDivider = NSView()
    private var selectionButton: CaptureToolbarButton!
    private var undoButton: CaptureToolbarButton!
    private var redoButton: CaptureToolbarButton!

    private let padding: CGFloat = 6
    private let spacing: CGFloat = 2
    private let groupGap: CGFloat = 11
    private let rowHeight: CGFloat = 32
    private let optionHeight: CGFloat = 40

    var onCommand: ((Command) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        isHidden = true
        options.isHidden = true
        addSubview(bar)
        addSubview(options)

        selectionButton = addButton(to: bar, "cursorarrow", "选区工具", .select(nil), tip: "选区工具 · Esc 退出标注", toggle: true)
        for tool in MarkTool.allCases {
            toolButtons[tool] = addButton(to: bar, tool.info.symbol, tool.info.title, .select(tool), toggle: true)
        }
        undoButton = addButton(to: bar, "arrow.uturn.backward", "撤销", .undo, tip: "撤销 ⌘Z")
        redoButton = addButton(to: bar, "arrow.uturn.forward", "重做", .redo, tip: "重做 ⇧⌘Z")
        groups = [
            [selectionButton],
            [.box, .ellipse, .arrow, .line].compactMap { toolButtons[$0] },
            [.pen, .highlighter, .text, .mosaic].compactMap { toolButtons[$0] },
            [undoButton, redoButton],
            [
                addButton(to: bar, "arrow.counterclockwise", "重选", .reselect, tip: "重选 · 右键"),
                addButton(to: bar, "translate", "翻译", .finish(.translate), tip: "原位翻译 T"),
                addButton(to: bar, "pin", "贴图", .finish(.pin), tip: "贴图 P"),
                addButton(to: bar, "square.and.arrow.down", "保存", .finish(.save), tip: "保存 ⌘S")
            ],
            [
                addButton(to: bar, "doc.on.doc", "复制", .finish(.copy), tip: "复制 ⏎ / ⌘C",
                          face: .primary, width: 66),
                addButton(to: bar, "xmark", "取消截图", .cancel, face: .dismiss)
            ]
        ]
        dividers = (1..<groups.count).map { _ in NSView() }
        for divider in dividers { installDivider(divider, in: bar) }

        for (color, name) in Self.palette {
            colorButtons.append(addButton(to: options, "", name, .color(color), face: .swatch(color), toggle: true))
        }
        installDivider(optionDivider, in: options)
        for index in 0..<3 {
            sizeButtons.append(addButton(to: options, "", "", .size(index), face: .stroke(index), width: 32, toggle: true))
        }
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func containsControl(at point: CGPoint) -> Bool {
        !isHidden && (bar.frame.contains(point) || (!options.isHidden && options.frame.contains(point)))
    }

    func overlaps(_ rect: CGRect) -> Bool {
        !isHidden && (bar.frame.intersects(rect) || (!options.isHidden && options.frame.intersects(rect)))
    }

    func show(near selection: CGRect, within available: CGRect, tool: MarkTool?, color: NSColor,
              size: Int, canUndo: Bool, canRedo: Bool) {
        isHidden = false
        selectionButton.state = tool == nil ? .on : .off
        for (mark, button) in toolButtons { button.state = tool == mark ? .on : .off }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo

        let barSize = layoutBar(maxWidth: available.width)
        let gap: CGFloat = 8
        let optionsGap: CGFloat = 5
        let spaceBelow = available.maxY - selection.maxY - gap
        let spaceAbove = selection.minY - available.minY - gap
        // Reserve space for the options so changing tools keeps the main bar in place.
        let fullHeight = barSize.height + optionsGap + optionHeight
        let below = spaceBelow >= fullHeight || (spaceAbove < fullHeight && spaceBelow >= spaceAbove)
        let proposedY = below ? selection.maxY + gap : selection.minY - gap - barSize.height
        bar.frame = CGRect(
            x: clamp(selection.maxX - barSize.width, from: available.minX, to: available.maxX - barSize.width),
            y: clamp(proposedY, from: available.minY, to: available.maxY - barSize.height),
            width: barSize.width, height: barSize.height
        )

        options.isHidden = tool == nil
        guard let tool, let button = toolButtons[tool] else { return }
        let optionWidth = layoutOptions(for: tool, color: color, size: size)
        let outerY = below ? bar.frame.maxY + optionsGap : bar.frame.minY - optionsGap - optionHeight
        let innerY = below ? bar.frame.minY - optionsGap - optionHeight : bar.frame.maxY + optionsGap
        let optionY = outerY >= available.minY && outerY + optionHeight <= available.maxY ? outerY : innerY
        options.frame = CGRect(
            x: clamp(bar.frame.minX + button.frame.midX - optionWidth / 2,
                     from: bar.frame.minX, to: bar.frame.maxX - optionWidth),
            y: clamp(optionY, from: available.minY, to: available.maxY - optionHeight),
            width: optionWidth, height: optionHeight
        )
    }

    private func layoutBar(maxWidth: CGFloat) -> CGSize {
        var x = padding
        var y = padding
        var right = x
        for (index, group) in groups.enumerated() {
            let width = group.reduce(CGFloat.zero) { $0 + $1.frame.width }
                + CGFloat(group.count - 1) * spacing
            if index > 0 {
                let divider = dividers[index - 1]
                let wraps = x + groupGap + width + padding > maxWidth
                divider.isHidden = wraps
                if wraps {
                    x = padding
                    y += rowHeight + spacing
                } else {
                    divider.frame = CGRect(x: x + 5, y: y + 7, width: 1, height: 18)
                    x += groupGap
                }
            }
            for button in group {
                button.setFrameOrigin(CGPoint(x: x, y: y))
                x += button.frame.width + spacing
            }
            x -= spacing
            right = max(x, right)
        }
        return CGSize(width: right + padding, height: y + rowHeight + padding)
    }

    private func layoutOptions(for tool: MarkTool, color: NSColor, size: Int) -> CGFloat {
        let showsColor = tool != .mosaic
        var x = padding
        for (index, button) in colorButtons.enumerated() {
            button.isHidden = !showsColor
            button.state = Self.palette[index].0 == color ? .on : .off
            button.setFrameOrigin(CGPoint(x: x, y: 4))
            x += button.frame.width + spacing
        }
        optionDivider.isHidden = !showsColor
        if showsColor {
            optionDivider.frame = CGRect(x: x + 2, y: 11, width: 1, height: 18)
            x += 8
        } else {
            x = padding
        }

        let labels: [String]
        switch tool {
        case .text: labels = ["小号文字", "中号文字", "大号文字"]
        case .mosaic: labels = ["细马赛克", "中马赛克", "粗马赛克"]
        default: labels = ["细线", "中等线宽", "粗线"]
        }
        for (index, button) in sizeButtons.enumerated() {
            switch tool {
            case .text: button.face = .textSize(index)
            case .mosaic: button.face = .mosaicSize(index)
            default: button.face = .stroke(index)
            }
            button.state = index == size ? .on : .off
            button.setLabel(labels[index])
            button.setFrameOrigin(CGPoint(x: x, y: 4))
            x += button.frame.width + spacing
        }
        return x - spacing + padding
    }

    private func addButton(to surface: NSView, _ symbol: String, _ label: String, _ command: Command,
                           tip: String? = nil, face: CaptureToolbarButton.Face = .normal,
                           width: CGFloat = 28, toggle: Bool = false) -> CaptureToolbarButton {
        let button = CaptureToolbarButton(frame: CGRect(x: 0, y: 0, width: width, height: rowHeight))
        button.configure(symbol: symbol, label: label, tip: tip, face: face, toggle: toggle)
        button.onPress = { [weak self] in self?.onCommand?(command) }
        surface.addSubview(button)
        return button
    }

    private func installDivider(_ divider: NSView, in surface: NSView) {
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        surface.addSubview(divider, positioned: .below, relativeTo: nil)
    }

    private func clamp(_ value: CGFloat, from lower: CGFloat, to upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper))
    }
}

private final class CaptureToolbarSurface: NSView {
    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.126, green: 0.135, blue: 0.158, alpha: 0.98).cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}

private final class CaptureToolbarButton: NSButton {
    enum Face {
        case normal, primary, dismiss, swatch(NSColor), stroke(Int), textSize(Int), mosaicSize(Int)
    }

    var face: Face = .normal { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    private var glyph: NSImage?
    private var isToggle = false
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(symbol: String, label: String, tip: String?, face: Face, toggle: Bool) {
        self.face = face
        isToggle = toggle
        glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        setButtonType(toggle ? .toggle : .momentaryChange)
        isBordered = false
        setLabel(label, tip: tip)
        target = self
        action = #selector(pressed)
    }

    func setLabel(_ label: String, tip: String? = nil) {
        setAccessibilityLabel(label)
        toolTip = tip ?? label
    }

    @objc private func pressed() { onPress?() }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let hover = isEnabled && hovered && pointer.map { bounds.contains($0) } == true
        let pressed = isEnabled && isHighlighted
        let selected = isToggle && state == .on
        let highlightRect = bounds.insetBy(dx: 0, dy: 2)
        let background = NSBezierPath(roundedRect: highlightRect, xRadius: 7, yRadius: 7)
        var ink = NSColor.white.withAlphaComponent(isEnabled ? 0.91 : 0.32)
        switch face {
        case .primary:
            NSColor(srgbRed: 0.16, green: 0.39, blue: 0.87, alpha: pressed ? 0.76 : 1).setFill()
            background.fill()
            if hover && !pressed { NSColor.white.withAlphaComponent(0.09).setFill(); background.fill() }
            ink = .white
        case .dismiss where hover || pressed:
            NSColor.systemRed.withAlphaComponent(pressed ? 0.3 : 0.17).setFill()
            background.fill()
            ink = NSColor(srgbRed: 1, green: 0.72, blue: 0.72, alpha: 1)
        default:
            if selected {
                NSColor(srgbRed: 0.26, green: 0.52, blue: 1, alpha: hover ? 0.36 : 0.27).setFill()
                background.fill()
                ink = NSColor(srgbRed: 0.85, green: 0.91, blue: 1, alpha: 1)
            }
            if hover || pressed {
                NSColor.white.withAlphaComponent(pressed ? 0.18 : 0.09).setFill()
                background.fill()
            }
        }

        switch face {
        case .swatch(let color):
            let dot = CGRect(x: bounds.midX - 6.5, y: bounds.midY - 6.5, width: 13, height: 13)
            let circle = NSBezierPath(ovalIn: dot)
            color.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if selected {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3))
                ink.setStroke()
                ring.lineWidth = 1
                ring.stroke()
            }
        case .stroke(let index):
            let weight: CGFloat = [1.4, 2.6, 4.3][index]
            let line = CGRect(x: bounds.midX - 7, y: bounds.midY - weight / 2, width: 14, height: weight)
            ink.setFill()
            NSBezierPath(roundedRect: line, xRadius: weight / 2, yRadius: weight / 2).fill()
        case .textSize(let index):
            drawTitle("A", font: .systemFont(ofSize: [10, 13, 17][index], weight: .semibold), color: ink, at: bounds.midX)
        case .mosaicSize(let index):
            let count = 4 - index
            let side: CGFloat = 14
            let block = side / CGFloat(count)
            for row in 0..<count {
                for column in 0..<count {
                    ink.withAlphaComponent((column + row).isMultiple(of: 2) ? 0.9 : 0.28).setFill()
                    NSBezierPath(rect: CGRect(x: bounds.midX - side / 2 + CGFloat(column) * block,
                                              y: bounds.midY - side / 2 + CGFloat(row) * block,
                                              width: block, height: block)).fill()
                }
            }
        case .primary:
            drawGlyph(at: 18, color: ink)
            drawTitle("复制", font: .systemFont(ofSize: 12, weight: .semibold), color: ink, at: 43)
        case .normal, .dismiss:
            drawGlyph(at: bounds.midX, color: ink)
        }
    }

    private func drawGlyph(at x: CGFloat, color: NSColor) {
        guard let glyph else { return }
        let rect = CGRect(x: x - glyph.size.width / 2, y: bounds.midY - glyph.size.height / 2,
                          width: glyph.size.width, height: glyph.size.height)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
        context.setFillColor(color.cgColor)
        context.setBlendMode(.sourceIn)
        context.fill(rect)
        context.endTransparencyLayer()
    }

    private func drawTitle(_ title: String, font: NSFont, color: NSColor, at x: CGFloat) {
        let string = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: CGPoint(x: x - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
