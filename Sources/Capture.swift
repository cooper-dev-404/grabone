import AppKit
import ScreenCaptureKit

enum CaptureAction { case copy, save, pin, translate }
enum CaptureMode { case standard, translate }

private final class CapturePanel: NSPanel {
    weak var canvas: CaptureCanvas?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptureController {
    private var panels: [CapturePanel] = []
    private var generation = UUID()
    private(set) var busy = false
    var onResult: ((CaptureDocument, CaptureAction, CGRect) -> Void)?
    var onError: ((String) -> Void)?
    var onPermission: (() -> Void)?

    func start(_ mode: CaptureMode) {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else { onPermission?(); return }
        busy = true
        let token = UUID()
        generation = token
        Task { [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let pid = ProcessInfo.processInfo.processIdentifier
                let excludedApps = Preferences.bool(Preferences.Key.excludeOwn)
                    ? content.applications.filter { $0.processID == pid } : []
                let windows = captureWindowOrder(content.windows, excludePID: !excludedApps.isEmpty ? pid : nil)
                var prepared: [(screen: NSScreen, image: CGImage, snapRects: [CGRect])] = []
                for screen in NSScreen.screens {
                    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
                    let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
                    cfg.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
                    guard cfg.width > 0, cfg.height > 0 else { continue }
                    cfg.showsCursor = Preferences.bool(Preferences.Key.cursor)
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    guard generation == token else { return }
                    let desktopRect = CGDisplayBounds(display.displayID)
                    let localLimit = CGRect(origin: .zero, size: screen.frame.size)
                    let snapRects = windows.map {
                        $0.frame.offsetBy(dx: -desktopRect.minX, dy: -desktopRect.minY).intersection(localLimit)
                    }.filter { !$0.isNull && $0.width >= 24 && $0.height >= 24 }
                    prepared.append((screen, image, snapRects))
                }
                guard generation == token else { return }
                guard !prepared.isEmpty else { cancel(); onError?("当前没有可截图的显示器。"); return }
                let mouse = NSEvent.mouseLocation
                for item in prepared {
                    let panel = CapturePanel(contentRect: item.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false, screen: item.screen)
                    panel.setFrame(item.screen.frame, display: false)
                    panel.level = .screenSaver
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                    panel.hidesOnDeactivate = false
                    panel.hasShadow = false
                    panel.acceptsMouseMovedEvents = true
                    let canvas = CaptureCanvas(frame: CGRect(origin: .zero, size: item.screen.frame.size),
                                               snapshot: item.image, snapRects: item.snapRects, mode: mode)
                    canvas.cancel = { [weak self] in self?.cancel() }
                    canvas.complete = { [weak self, weak canvas] document, action, area in
                        guard let self, let canvas, let source = canvas.window else { return }
                        let frame = source.convertToScreen(canvas.convert(area, to: nil))
                        self.cancel()
                        self.onResult?(document, action, frame)
                    }
                    canvas.onBeginSelecting = { [weak self, weak panel] in
                        guard let self, let panel else { return }
                        for other in self.panels where other !== panel {
                            other.canvas?.clearSelection()
                        }
                    }
                    panel.canvas = canvas
                    panel.contentView = canvas.hostingView()
                    panel.makeFirstResponder(canvas)
                    panels.append(panel)
                    panel.orderFrontRegardless()
                    if item.screen.frame.contains(mouse) { panel.makeKey() }
                }
                if !panels.contains(where: { $0.isKeyWindow }) { panels.first?.makeKey() }
            } catch {
                guard generation == token else { return }
                cancel()
                onError?("无法取得屏幕画面。\n" + error.localizedDescription)
            }
        }
    }

    func cancel() {
        generation = UUID()
        busy = false
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    private func captureWindowOrder(_ windows: [SCWindow], excludePID: pid_t?) -> [SCWindow] {
        let eligible = windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 24 && $0.frame.height > 24 &&
            (excludePID == nil || $0.owningApplication?.processID != excludePID)
        }
        let items = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let indices = Dictionary(uniqueKeysWithValues: items.enumerated().compactMap { index, row -> (UInt32, Int)? in
            guard let id = row[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (id.uint32Value, index)
        })
        return eligible.sorted { indices[$0.windowID, default: Int.max] < indices[$1.windowID, default: Int.max] }
    }
}

@MainActor
private final class CaptureCanvas: NSView, NSTextFieldDelegate {
    private enum Drag { case new(CGPoint), move(CGPoint, CGRect), resize(CGRect, Int, Int), mark }

    private struct AnnotationStyle {
        var color: NSColor
        var size = 1
        var width: CGFloat { [1.6, 2.8, 4.8][size] }
    }
    private let snapshot: CGImage
    private let snapRects: [CGRect]
    private let mode: CaptureMode
    private let accent = Preferences.accent
    private let toolbar = CaptureToolbar(frame: .zero)
    private var selection: CGRect?
    private var suggested: CGRect?
    private var pointer: CGPoint?
    private var drag: Drag?
    private var activeTool: MarkTool?
    private var currentMark: Mark?
    private var marks: [Mark] = []
    private var undone: [Mark] = []
    private var field: NSTextField?
    private var textOrigin: CGPoint?
    private var manualSelection = false
    private var inkStyle = AnnotationStyle(color: .systemRed)
    private var highlightStyle = AnnotationStyle(color: .systemYellow)
    private var textStyle = AnnotationStyle(color: .systemRed)
    private var mosaicStyle = AnnotationStyle(color: .clear)

    private var style: AnnotationStyle {
        get {
            switch activeTool {
            case .highlighter: highlightStyle
            case .text: textStyle
            case .mosaic: mosaicStyle
            default: inkStyle
            }
        }
        set {
            switch activeTool {
            case .highlighter: highlightStyle = newValue
            case .text: textStyle = newValue
            case .mosaic: mosaicStyle = newValue
            default: inkStyle = newValue
            }
        }
    }

    var cancel: (() -> Void)?
    var complete: ((CaptureDocument, CaptureAction, CGRect) -> Void)?
    var onBeginSelecting: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, snapshot: CGImage, snapRects: [CGRect], mode: CaptureMode) {
        self.snapshot = snapshot
        self.snapRects = snapRects
        self.mode = mode
        super.init(frame: frame)
        toolbar.frame = bounds
        toolbar.onCommand = { [weak self] command in self?.perform(command) }
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { nil }

    func hostingView() -> NSView {
        let container = NSView(frame: frame)
        container.wantsLayer = true
        let backdrop = NSView(frame: frame)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.contents = snapshot
        backdrop.layer?.contentsGravity = .resize
        container.addSubview(backdrop)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        return container
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.frame.contains(NSEvent.mouseLocation) {
            pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateSuggestion()
        }
    }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
            .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { pointer = nil; suggested = nil; needsDisplay = true }

    override func mouseMoved(with event: NSEvent) {
        pointer = point(event)
        updateSuggestion()
        if let pointer { cursor(at: pointer).set() }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let location = point(event)
        pointer = location
        window?.makeKey()
        commitText()
        window?.makeFirstResponder(self)
        onBeginSelecting?()
        if event.clickCount == 2, let selection, selection.contains(location), activeTool == nil {
            finish(mode == .translate ? .translate : .copy)
            return
        }
        if let selection, let tool = activeTool, selection.contains(location) {
            let origin = location - selection.origin
            if tool == .text { beginText(at: location, relative: origin); return }
            currentMark = Mark(tool: tool, origin: origin, color: style.color, width: style.width)
            drag = .mark
        } else if let selection, marks.isEmpty, selection.insetBy(dx: -5, dy: -5).contains(location) {
            let (x, y) = resizeEdges(at: location, area: selection)
            drag = x == 0 && y == 0 ? .move(location, selection) : .resize(selection, x, y)
            if x == 0 && y == 0 { NSCursor.closedHand.set() }
        } else if marks.isEmpty {
            selection = nil
            activeTool = nil
            undone.removeAll()
            drag = .new(location)
        }
        updateUI()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = point(event)
        pointer = location
        guard let drag else { return }
        switch drag {
        case .new(let start): selection = rect(from: start, to: location)
        case .move(let start, let area): selection = move(area, by: location - start)
        case .resize(let area, let x, let y): selection = resize(area, location: location, x: x, y: y)
        case .mark:
            guard let selection else { return }
            if currentMark?.tool == .pen || currentMark?.tool == .highlighter {
                currentMark?.points.append(location - selection.origin)
            } else { currentMark?.points = [location - selection.origin] }
            needsDisplay = true
            return
        }
        updateUI()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .new:
            if !validSelection, let suggested { selection = suggested }
            if !validSelection { selection = nil }
            if validSelection && mode == .translate { finish(.translate); return }
        case .mark:
            if let currentMark, !currentMark.points.isEmpty { append(currentMark) }
            currentMark = nil
        case .move, .resize: break
        }
        updateSuggestion()
        updateUI()
        cursor(at: point(event)).set()
    }

    override func rightMouseDown(with event: NSEvent) {
        if selection != nil && mode == .standard { clearSelection() }
        else { cancel?() }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, key) {
        case (53, _):
            if activeTool == nil { cancel?() }
            else { activeTool = nil; updateUI() }
        case (36, _), (76, _): finish(mode == .translate ? .translate : .copy)
        case (48, _): manualSelection.toggle(); updateSuggestion(); needsDisplay = true
        case (_, "c") where mods.contains(.command): finish(.copy)
        case (_, "s") where mods.contains(.command): finish(.save)
        case (_, "z") where mods.contains(.command):
            if mods.contains(.shift) { redo() } else { undo() }
        case (_, "p") where mods.isEmpty: finish(.pin)
        case (_, "t") where mods.isEmpty: finish(.translate)
        case (_, "a") where mods.isEmpty:
            guard marks.isEmpty else { return }
            selection = bounds
            updateUI()
        case (123...126, _): nudge(event.keyCode, resize: mods.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    func clearSelection() {
        field?.removeFromSuperview()
        field = nil
        textOrigin = nil
        activeTool = nil
        selection = nil
        marks.removeAll()
        undone.removeAll()
        currentMark = nil
        drag = nil
        updateSuggestion()
        updateUI()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private var validSelection: Bool {
        guard let selection else { return false }
        return selection.width >= 2 && selection.height >= 2
    }

    private func updateSuggestion() {
        if let pointer, selection == nil, !manualSelection, Preferences.bool(Preferences.Key.snap) {
            suggested = snapRects.first(where: { $0.contains(pointer) })
        } else { suggested = nil }
    }

    private func resizeEdges(at point: CGPoint, area: CGRect) -> (Int, Int) {
        let x = abs(point.x - area.minX) <= 6 ? -1 : abs(point.x - area.maxX) <= 6 ? 1 : 0
        let y = abs(point.y - area.minY) <= 6 ? -1 : abs(point.y - area.maxY) <= 6 ? 1 : 0
        return (x, y)
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        if toolbar.containsControl(at: point) { return .arrow }
        guard let selection else { return .crosshair }
        if let activeTool, selection.contains(point) { return activeTool == .text ? .iBeam : .crosshair }
        if !marks.isEmpty { return .arrow }
        guard selection.insetBy(dx: -5, dy: -5).contains(point) else { return .crosshair }
        let (x, y) = resizeEdges(at: point, area: selection)
        if x != 0 { return .resizeLeftRight }
        if y != 0 { return .resizeUpDown }
        return .openHand
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func move(_ area: CGRect, by delta: CGPoint) -> CGRect {
        CGRect(x: min(max(0, area.minX + delta.x), bounds.width - area.width),
               y: min(max(0, area.minY + delta.y), bounds.height - area.height),
               width: area.width, height: area.height)
    }

    private func resize(_ area: CGRect, location: CGPoint, x: Int, y: Int) -> CGRect {
        let left = x < 0 ? min(location.x, area.maxX - 2) : area.minX
        let right = x > 0 ? max(location.x, area.minX + 2) : area.maxX
        let top = y < 0 ? min(location.y, area.maxY - 2) : area.minY
        let bottom = y > 0 ? max(location.y, area.minY + 2) : area.maxY
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func nudge(_ keyCode: UInt16, resize: Bool) {
        guard let selection, marks.isEmpty else { return }
        let dx: CGFloat = keyCode == 123 ? -1 : keyCode == 124 ? 1 : 0
        let dy: CGFloat = keyCode == 126 ? -1 : keyCode == 125 ? 1 : 0
        let pixel = bounds.width / CGFloat(snapshot.width)
        if resize {
            let right = min(bounds.width, max(selection.minX + 2, selection.maxX + dx * pixel))
            let bottom = min(bounds.height, max(selection.minY + 2, selection.maxY + dy * pixel))
            self.selection = CGRect(x: selection.minX, y: selection.minY,
                                    width: right - selection.minX, height: bottom - selection.minY)
        } else { self.selection = move(selection, by: CGPoint(x: dx * pixel, y: dy * pixel)) }
        updateUI()
    }

    private func makeDocument(_ area: CGRect) -> CaptureDocument? {
        guard let pixels = ImageGeometry.pixelRect(area, in: bounds.size, image: snapshot),
              let original = snapshot.cropping(to: pixels) else { return nil }
        return CaptureDocument(original: original, logicalSize: area.size, annotations: marks)
    }

    private func finish(_ action: CaptureAction) {
        commitText()
        guard let area = selection ?? suggested, let document = makeDocument(area) else { return }
        complete?(document, action, area)
    }

    private func append(_ mark: Mark) {
        marks.append(mark)
        undone.removeAll()
    }

    private func beginText(at location: CGPoint, relative: CGPoint) {
        guard let selection else { return }
        let width = min(260, selection.maxX - location.x)
        guard width >= 24 else { return }
        let field = NSTextField(frame: CGRect(x: location.x, y: location.y, width: width, height: 25))
        field.font = .systemFont(ofSize: 10 + style.width * 3, weight: .semibold)
        field.placeholderString = "输入文字"
        field.delegate = self
        field.target = self
        field.action = #selector(endText)
        self.field = field
        textOrigin = relative
        addSubview(field, positioned: .below, relativeTo: toolbar)
        window?.makeFirstResponder(field)
    }

    @objc private func endText() {
        commitText()
        window?.makeFirstResponder(self)
        updateUI()
    }

    private func commitText() {
        guard let field, let origin = textOrigin else { return }
        let content = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        self.field = nil
        textOrigin = nil
        if !content.isEmpty {
            append(Mark(tool: .text, origin: origin, color: style.color, width: style.width, text: content))
        }
    }

    func controlTextDidChange(_ obj: Notification) { updateUI() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        field?.removeFromSuperview()
        field = nil
        textOrigin = nil
        window?.makeFirstResponder(self)
        updateUI()
        return true
    }

    private func perform(_ command: CaptureToolbar.Command) {
        switch command {
        case .finish(let action): finish(action); return
        case .cancel: cancel?(); return
        case .reselect: clearSelection()
        case .select(let tool):
            commitText()
            activeTool = activeTool == tool ? nil : tool
        case .color(let color):
            commitText()
            style.color = color
        case .size(let size):
            commitText()
            style.size = size
        case .undo:
            undo()
        case .redo:
            redo()
        }
        window?.makeFirstResponder(self)
        updateUI()
    }

    private func undo() {
        commitText()
        if let mark = marks.popLast() { undone.append(mark) }
        updateUI()
    }

    private func redo() {
        if let mark = undone.popLast() { marks.append(mark) }
        updateUI()
    }

    private func updateUI() {
        needsDisplay = true
        guard mode == .standard, validSelection, let selection else {
            toolbar.isHidden = true
            return
        }
        if case .new = drag {
            toolbar.isHidden = true
            return
        }

        let safeInsets = window?.screen?.safeAreaInsets ?? NSEdgeInsets()
        let available = CGRect(x: bounds.minX + 9 + safeInsets.left, y: bounds.minY + 9 + safeInsets.top,
                               width: bounds.width - 18 - safeInsets.left - safeInsets.right,
                               height: bounds.height - 18 - safeInsets.top - safeInsets.bottom)
        let hasDraft = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        toolbar.show(near: selection, within: available, tool: activeTool, color: style.color,
                     size: style.size, canUndo: !marks.isEmpty || hasDraft, canRedo: !undone.isEmpty && !hasDraft)
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let area = selection ?? suggested
        let mask = CGMutablePath()
        mask.addRect(bounds)
        if let area { mask.addRect(area) }
        context.setFillColor(NSColor.black.withAlphaComponent(Preferences.number(Preferences.Key.mask)).cgColor)
        context.addPath(mask)
        context.drawPath(using: .eoFill)
        if let area { drawSelection(area, in: context) }
        if let pointer, !validSelection {
            if Preferences.bool(Preferences.Key.crosshair) { drawCrosshair(at: pointer, in: context) }
            if Preferences.bool(Preferences.Key.magnifier) { drawMagnifier(at: pointer, in: context) }
        }
        if !validSelection, Preferences.bool(Preferences.Key.hints) { drawHint(in: context) }
    }

    private func drawSelection(_ area: CGRect, in context: CGContext) {
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(Preferences.number(Preferences.Key.border))
        context.stroke(area)
        guard let pixels = ImageGeometry.pixelRect(area, in: bounds.size, image: snapshot) else { return }
        if validSelection {
            context.setFillColor(accent.cgColor)
            if marks.isEmpty && activeTool == nil && Preferences.bool(Preferences.Key.anchors) {
                let outline = UserDefaults.standard.integer(forKey: Preferences.Key.anchorOutline)
                let strokeWidth = 1 / (window?.backingScaleFactor ?? 1)
                if outline >= 0 {
                    context.setStrokeColor(Preferences.anchorOutlineColor(outline).cgColor)
                    context.setLineWidth(strokeWidth)
                }
                for x in [area.minX, area.midX, area.maxX] {
                    for y in [area.minY, area.midY, area.maxY] where x != area.midX || y != area.midY {
                        let anchor = CGRect(x: x - 2.25, y: y - 2.25, width: 4.5, height: 4.5)
                        context.fill(anchor)
                        if outline >= 0 {
                            context.stroke(anchor.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
                        }
                    }
                }
            }
            if !marks.isEmpty || currentMark != nil {
                let hasMosaic = currentMark?.tool == .mosaic || marks.contains(where: { $0.tool == .mosaic })
                let source = hasMosaic ? snapshot.cropping(to: pixels) ?? snapshot : snapshot
                context.saveGState()
                context.clip(to: area)
                context.translateBy(x: area.minX, y: area.minY)
                for mark in marks { mark.draw(in: context, source: source, size: area.size) }
                currentMark?.draw(in: context, source: source, size: area.size)
                context.restoreGState()
            }
        }
        let size = "\(Int(pixels.width)) × \(Int(pixels.height))"
        let x = min(max(7, area.minX), bounds.width - 110)
        let badgeLocations = [area.minY - 25, area.maxY + 4, area.minY + 5].map { y in
            CGRect(x: x, y: min(max(7, y), bounds.height - 28), width: 104, height: 21)
        }
        let badge = badgeLocations.first(where: { !toolbar.overlaps($0) }) ?? badgeLocations[0]
        label(size, rect: badge, in: context)
    }

    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.setLineWidth(1 / (window?.backingScaleFactor ?? 1))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
        context.move(to: CGPoint(x: 0, y: point.y))
        context.addLine(to: CGPoint(x: bounds.width, y: point.y))
        context.move(to: CGPoint(x: point.x, y: 0))
        context.addLine(to: CGPoint(x: point.x, y: bounds.height))
        context.strokePath()
    }

    private func drawMagnifier(at point: CGPoint, in context: CGContext) {
        let scale = CGFloat(snapshot.width) / bounds.width
        let scaleY = CGFloat(snapshot.height) / bounds.height
        let zoom = max(1, Preferences.number(Preferences.Key.magnifierZoom))
        let side = (105 / zoom).rounded()
        guard let pixels = ImageGeometry.pixelRect(
            CGRect(x: point.x - side / (2 * scale), y: point.y - side / (2 * scaleY),
                   width: side / scale, height: side / scaleY),
            in: bounds.size, image: snapshot), let portion = snapshot.cropping(to: pixels) else { return }
        let x = point.x + 142 < bounds.width ? point.x + 18 : max(4, point.x - 126)
        let y = point.y + 142 < bounds.height ? point.y + 18 : max(4, point.y - 126)
        let display = CGRect(x: x, y: y, width: 105, height: 105)
        context.saveGState()
        context.interpolationQuality = .none
        drawImage(portion, in: display, context: context)
        context.setLineWidth(2)
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(display)
        context.setLineWidth(1)
        context.setStrokeColor(accent.cgColor)
        let shiftX = (point.x * scale - pixels.minX) / pixels.width
        let shiftY = (point.y * scaleY - pixels.minY) / pixels.height
        let crossX = display.minX + display.width * shiftX
        let crossY = display.minY + display.height * shiftY
        context.move(to: CGPoint(x: display.minX, y: crossY))
        context.addLine(to: CGPoint(x: display.maxX, y: crossY))
        context.move(to: CGPoint(x: crossX, y: display.minY))
        context.addLine(to: CGPoint(x: crossX, y: display.maxY))
        context.strokePath()
        context.restoreGState()
    }

    private func drawHint(in context: CGContext) {
        let title = mode == .translate ? "框选文字 · 松开即翻译 · Esc 取消"
            : "拖动框选 · Tab 切换窗口吸附 · A 当前屏幕 · Esc 取消"
        label(title, rect: CGRect(x: bounds.midX - 174, y: 23, width: 348, height: 26), in: context)
    }

    private func label(_ title: String, rect: CGRect, in context: CGContext) {
        context.setFillColor(NSColor.black.withAlphaComponent(0.80).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        drawText(title, in: rect.insetBy(dx: 8, dy: 4), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                 color: .white, context: context)
    }
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
