import AppKit
import SwiftUI

private final class FloatingPinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PinController {
    private var pins: [PinWindow] = []
    private(set) var isHidden = false
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTranslationSettings: (() -> Void)?

    var count: Int { pins.count }
    var hasClickThrough: Bool { pins.contains { $0.isClickThrough } }
    var windowItems: [(title: String, ID: UUID)] { pins.map { ($0.displayTitle, $0.id) } }

    func show(_ document: CaptureDocument, placement: CGRect?, translate: Bool) {
        let pin = PinWindow(document: document)
        pin.onClose = { [weak self, weak pin] in
            self?.pins.removeAll { $0 === pin }
            if self?.pins.isEmpty == true { self?.isHidden = false }
            self?.onChange?()
        }
        pin.onChange = { [weak self] in self?.onChange?() }
        pin.onError = { [weak self] message in self?.onError?(message) }
        pin.onTranslationSettings = { [weak self] in self?.onTranslationSettings?() }
        if isHidden { setHidden(false) }
        pins.append(pin)
        pin.show(at: placement, translate: translate)
        onChange?()
    }

    func paste() {
        guard let image = NSImage(pasteboard: .general), let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              bitmap.width > 0, bitmap.height > 0 else { onError?("剪贴板里没有可贴出的图片。"); return }
        let size = image.size.width > 0 && image.size.height > 0
            ? image.size : CGSize(width: bitmap.width, height: bitmap.height)
        show(CaptureDocument(original: bitmap, logicalSize: size), placement: nil, translate: false)
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        for pin in pins { pin.setHidden(hidden) }
        onChange?()
    }

    func closeAll() {
        for pin in Array(pins) { pin.close() }
    }

    func resetClickThrough() {
        for pin in pins { pin.setClickThrough(false) }
        onChange?()
    }

    func focus(_ id: UUID) {
        if isHidden { setHidden(false) }
        pins.first { $0.id == id }?.bringForward()
    }

    func applySpacePreference() {
        for pin in pins { pin.applySpacePreference() }
    }
}

@MainActor
private final class PinWindow: NSObject, NSWindowDelegate {
    let id = UUID()
    private let document: CaptureDocument
    private let rendered: CGImage
    private let panel: FloatingPinPanel
    private let imageView: PinImageView
    private let translator: OverlayTranslation
    private let translateButton: NSButton
    private let toggleButton: NSButton
    private let copyButton = NSButton()
    private let titleHeight: CGFloat = 28
    private let footerHeight: CGFloat = 30
    private var chromeHeight: CGFloat { titleHeight + footerHeight }
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTranslationSettings: (() -> Void)?

    private var showingTranslation = false
    private var revealFirstTranslation = false
    private var opacity = 1.0
    var isClickThrough: Bool { panel.ignoresMouseEvents }
    var displayTitle: String { "\(rendered.width) × \(rendered.height) · " + (showingTranslation ? "译文" : "贴图") }

    init(document: CaptureDocument) {
        self.document = document
        rendered = document.output
        imageView = PinImageView(image: rendered)
        translator = OverlayTranslation(image: document.original)
        panel = FloatingPinPanel(contentRect: CGRect(x: 0, y: 0, width: 348, height: 230),
                                 styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        translateButton = NSButton()
        toggleButton = NSButton()
        super.init()
        configure()
    }

    private func configure() {
        panel.title = "截一屏贴图"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = CGSize(width: 220, height: 88)
        panel.delegate = self
        opacity = Preferences.number(Preferences.Key.pinOpacity)
        panel.alphaValue = opacity
        applySpacePreference()

        let root = NSView()
        panel.contentView = root
        let titleSpacing = NSVisualEffectView()
        titleSpacing.material = .titlebar
        titleSpacing.state = .active
        titleSpacing.blendingMode = .withinWindow
        let footer = NSVisualEffectView()
        footer.material = .hudWindow
        footer.state = .active
        footer.blendingMode = .withinWindow
        let size = NSTextField(labelWithString: "\(rendered.width) × \(rendered.height)")
        size.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        size.textColor = .secondaryLabelColor

        configureButton(translateButton, "translate", "翻译或重新翻译", #selector(translate))
        configureButton(toggleButton, "eye", "切换原图与译文", #selector(toggleTranslation))
        toggleButton.isHidden = true
        toggleButton.isEnabled = false
        configureButton(copyButton, "doc.on.doc", "复制截图", #selector(copyImage))
        let menuButton = NSButton()
        configureButton(menuButton, "ellipsis.circle", "贴图操作", #selector(openMenu(_:)))
        let buttons = NSStackView(views: [translateButton, toggleButton, copyButton, menuButton])
        buttons.spacing = 3
        let status = NSHostingView(rootView: TranslationStatusView(model: translator))
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [titleSpacing, imageView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        size.translatesAutoresizingMaskIntoConstraints = false
        titleSpacing.addSubview(size)
        footer.addSubview(status)
        footer.addSubview(buttons)
        status.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleSpacing.topAnchor.constraint(equalTo: root.topAnchor), titleSpacing.heightAnchor.constraint(equalToConstant: titleHeight),
            titleSpacing.leadingAnchor.constraint(equalTo: root.leadingAnchor), titleSpacing.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            size.leadingAnchor.constraint(greaterThanOrEqualTo: titleSpacing.leadingAnchor, constant: 72),
            size.trailingAnchor.constraint(equalTo: titleSpacing.trailingAnchor, constant: -10),
            size.centerYAnchor.constraint(equalTo: titleSpacing.centerYAnchor, constant: 2),
            imageView.topAnchor.constraint(equalTo: titleSpacing.bottomAnchor), imageView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: footerHeight),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10), status.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -7),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        translator.onChange = { [weak self] in self?.updateTranslation() }
        imageView.menuProvider = { [weak self] in self?.contextMenu() }
        imageView.onDoubleClick = { [weak self] in self?.doubleClick() }
        imageView.onZoom = { [weak self] factor in self?.zoom(factor) }
        imageView.onKey = { [weak self] event in self?.handle(event) ?? false }
        panel.makeFirstResponder(imageView)
    }

    private func configureButton(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "character", accessibilityDescription: label)
        button.image = image
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        if button === translateButton {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 27).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        } else {
            button.widthAnchor.constraint(equalToConstant: 27).isActive = true
        }
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    func show(at placement: CGRect?, translate: Bool) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(placement.map { CGPoint(x: $0.midX, y: $0.midY) } ?? cursor) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 780)
        let size = initialSize(in: visible)
        let width = size.width
        let height = size.height
        let x = placement.map { $0.minX } ?? cursor.x - width / 2
        let y = placement.map { $0.maxY + titleHeight - height } ?? cursor.y - height / 2
        panel.setFrame(clamp(CGRect(x: x, y: y, width: width, height: height), to: visible), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        if translate { self.translate() }
    }

    func setHidden(_ hidden: Bool) {
        if hidden { panel.orderOut(nil) }
        else { panel.orderFrontRegardless() }
    }
    func close() { panel.close() }
    func bringForward() { panel.orderFrontRegardless(); panel.makeKey() }

    func applySpacePreference() {
        panel.collectionBehavior = Preferences.bool(Preferences.Key.allSpaces)
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    }

    func setClickThrough(_ enabled: Bool) {
        guard panel.ignoresMouseEvents != enabled else { return }
        panel.ignoresMouseEvents = enabled
        onChange?()
    }

    func windowWillClose(_ notification: Notification) {
        translator.cancel()
        onClose?()
    }

    private func updateTranslation() {
        let label = translationActionTitle
        let symbol: String
        if translator.phase.busy { symbol = "stop.circle" }
        else if case .failed = translator.phase { symbol = "arrow.clockwise" }
        else { symbol = "translate" }
        translateButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        if case .failed = translator.phase {
            translateButton.title = "重试"
            translateButton.font = .systemFont(ofSize: 11)
            translateButton.imagePosition = .imageLeading
        } else {
            translateButton.title = ""
            translateButton.imagePosition = .imageOnly
        }
        translateButton.toolTip = label
        translateButton.setAccessibilityLabel(label)
        if revealFirstTranslation && !translator.lines.isEmpty {
            showingTranslation = true
            revealFirstTranslation = false
        }
        toggleButton.isHidden = translator.lines.isEmpty
        toggleButton.isEnabled = !translator.lines.isEmpty
        displayOverlay()
    }

    private var translationActionTitle: String {
        if translator.phase.busy { return "停止翻译" }
        if case .failed = translator.phase { return "重试翻译" }
        return translator.lines.isEmpty ? "原位翻译" : "重新翻译"
    }

    @objc private func translate() {
        if translator.phase.busy {
            translator.cancel()
            return
        }
        revealFirstTranslation = true
        showingTranslation = false
        translator.start()
    }

    @objc private func openTranslationSettings() { onTranslationSettings?() }

    @objc private func toggleTranslation() {
        guard !translator.lines.isEmpty else { return }
        showingTranslation.toggle()
        displayOverlay()
    }

    private func displayOverlay() {
        imageView.overlay = showingTranslation ? translator.lines : []
        toggleButton.image = NSImage(systemSymbolName: showingTranslation ? "eye.slash" : "eye", accessibilityDescription: "切换原图与译文")
        onChange?()
    }

    @objc private func copyImage() {
        CaptureDocument.copy(rendered)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制截图")
        }
    }
    @objc private func copyOriginal() { CaptureDocument.copy(document.original) }
    @objc private func copyTranslation() { copyText(translator.lines.map(\.text).joined(separator: "\n")) }
    @objc private func copyRecognized() { copyText(translator.recognized.map(\.text).joined(separator: "\n")) }

    private func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func saveImage() {
        CaptureDocument.save(rendered, owner: panel) { [weak self] in self?.onError?($0) }
    }
    @objc private func saveOriginal() {
        CaptureDocument.save(document.original, owner: panel) { [weak self] in self?.onError?($0) }
    }
    @objc private func turnClickThrough() { setClickThrough(true) }
    @objc private func closeItem() { close() }
    @objc private func changeOpacity(_ item: NSMenuItem) {
        opacity = Double(item.tag) / 100
        panel.alphaValue = opacity
    }

    private func doubleClick() {
        if Preferences.string(Preferences.Key.doubleClick) == "close" { close() }
        else if !translator.lines.isEmpty { toggleTranslation() }
        else { resetZoom() }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }
        let key = event.charactersIgnoringModifiers?.lowercased()
        let cmd = event.modifierFlags.contains(.command)
        switch (key, cmd) {
        case ("c", true): copyImage()
        case ("s", true): saveImage()
        case ("0", true): resetZoom()
        case ("t", false):
            if !translator.lines.isEmpty { toggleTranslation() }
            else if !translator.phase.busy { translate() }
        case ("+", _), ("=", _): zoom(1.17)
        case ("-", _): zoom(1 / 1.17)
        default: return false
        }
        return true
    }

    private func zoom(_ factor: CGFloat) {
        guard let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let old = panel.frame
        let width = min(visible.width, max(panel.minSize.width, old.width * factor))
        let height = min(visible.height, max(panel.minSize.height, (old.height - chromeHeight) * factor + chromeHeight))
        setSize(CGSize(width: width, height: height), in: visible)
    }

    private func initialSize(in visible: CGRect) -> CGSize {
        let size = document.logicalSize
        let scale = min(1, visible.width * 0.83 / size.width, max(1, visible.height * 0.80 - chromeHeight) / size.height)
        return CGSize(width: max(panel.minSize.width, size.width * scale),
                      height: max(panel.minSize.height, size.height * scale + chromeHeight))
    }

    @objc private func resetZoom() {
        guard let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        setSize(initialSize(in: visible), in: visible)
    }

    private func setSize(_ size: CGSize, in visible: CGRect) {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setFrame(clamp(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                    width: size.width, height: size.height), to: visible), display: true)
    }

    private func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(x: max(bounds.minX, min(bounds.maxX - rect.width, rect.minX)),
               y: max(bounds.minY, min(bounds.maxY - rect.height, rect.minY)),
               width: rect.width, height: rect.height)
    }

    @objc private func openMenu(_ button: NSButton) {
        contextMenu().popUp(positioning: nil, at: CGPoint(x: 4, y: button.bounds.maxY), in: button)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
        add("复制截图", #selector(copyImage))
        add("复制原图", #selector(copyOriginal), enabled: !document.annotations.isEmpty)
        add("保存截图…", #selector(saveImage))
        if !document.annotations.isEmpty { add("保存原图…", #selector(saveOriginal)) }
        menu.addItem(.separator())
        if case .failed(let reason) = translator.phase { add(reason, #selector(translate), enabled: false) }
        add(translationActionTitle, #selector(translate))
        if case .failed = translator.phase { add("翻译设置…", #selector(openTranslationSettings)) }
        add(showingTranslation ? "查看原图" : "显示译文", #selector(toggleTranslation), enabled: !translator.lines.isEmpty)
        add("复制译文", #selector(copyTranslation), enabled: !translator.lines.isEmpty)
        add("复制识别文字", #selector(copyRecognized), enabled: !translator.recognized.isEmpty)
        menu.addItem(.separator())
        add("恢复贴图大小", #selector(resetZoom))
        let opacityItem = menu.addItem(withTitle: "不透明度", action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for level in [100, 85, 70, 55, 40, 25] {
            let item = levels.addItem(withTitle: "\(level)%", action: #selector(changeOpacity(_:)), keyEquivalent: "")
            item.tag = level
            item.target = self
            item.state = abs(opacity * 100 - Double(level)) < 1 ? .on : .off
        }
        opacityItem.submenu = levels
        add("鼠标穿透", #selector(turnClickThrough))
        add("关闭贴图", #selector(closeItem))
        return menu
    }
}

@MainActor
private final class PinImageView: NSView {
    private let image: CGImage
    var overlay: [TranslatedLine] = [] { didSet { needsDisplay = true; refreshToolTips() } }
    var menuProvider: (() -> NSMenu?)?
    var onDoubleClick: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityLabel("截图预览")
    }
    required init?(coder: NSCoder) { nil }

    private var imageRect: CGRect {
        ImageGeometry.fit(CGSize(width: image.width, height: image.height), in: bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        refreshToolTips()
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)
        let area = imageRect
        drawImage(image, in: area, context: context)
        for line in overlay { line.draw(in: area, context: context) }
    }

    private func refreshToolTips() {
        removeAllToolTips()
        for line in overlay {
            addToolTip(line.source.displayRect(in: imageRect), owner: self, userData: nil)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData: UnsafeMutableRawPointer?) -> String {
        overlay.first { $0.source.displayRect(in: imageRect).contains(point) }?.text ?? ""
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick?() }
        else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard Preferences.bool(Preferences.Key.scrollZoom), event.scrollingDeltaY != 0 else { return }
        let delta = min(4, max(-4, event.scrollingDeltaY))
        onZoom?(pow(1.034, delta))
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
