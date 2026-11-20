import AppKit

@main
enum GrabOne {
    @MainActor
    static func main() {
        Preferences.configure()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = ApplicationController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
private final class ApplicationController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkeys = Hotkeys()
    private let capture = CaptureController()
    private let pins = PinController()
    private lazy var settings = SettingsController(hotkeys: hotkeys)
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var permissionAlert: NSAlert?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let fallback = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "截一屏")
        let image = NSImage(named: "StatusItemTemplate") ?? fallback
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = image
        status.button?.setAccessibilityLabel("截一屏")
        status.button?.toolTip = "截一屏 · 截图、贴图、原位翻译"
        status.menu = menu
        menu.delegate = self
        hotkeys.onPress = { [weak self] in self?.perform($0) }
        hotkeys.install()

        capture.onPermission = { [weak self] in self?.showPermission() }
        capture.onError = { [weak self] in self?.showMessage($0) }
        capture.onResult = { [weak self] document, action, frame in
            guard let self else { return }
            switch action {
            case .copy: CaptureDocument.copy(document.output)
            case .save: CaptureDocument.save(document.output, failure: self.showMessage)
            case .pin: self.pins.show(document, placement: frame, translate: false)
            case .translate: self.pins.show(document, placement: frame, translate: true)
            }
        }
        pins.onTranslationSettings = { [weak self] in self?.settings.showTranslation() }
        pins.onError = { [weak self] in self?.showMessage($0) }
        settings.onPermission = { [weak self] in self?.showPermission() }
        settings.onApplyPinSpace = { [weak self] in self?.pins.applySpacePreference() }
        installMainMenu()
        if CommandLine.arguments.contains("--settings") { settings.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if capture.busy { capture.cancel() }
    }

    func applicationWillTerminate(_ notification: Notification) { hotkeys.uninstall() }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "截一屏")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let item = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        item.target = self
        appMenu.addItem(withTitle: "快捷键…", action: #selector(openShortcuts), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出截一屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for action in HotkeyAction.allCases {
            let item = menu.addItem(withTitle: action.title, action: #selector(trigger(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(action.rawValue)
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if !hotkeys.conflicts.contains(action), let shortcut = hotkeys.bindings[action] {
                item.keyEquivalent = shortcut.key
                item.keyEquivalentModifierMask = shortcut.modifiers
            }
        }
        if pins.count > 0 {
            menu.addItem(.separator())
            add(pins.isHidden ? "显示所有贴图" : "隐藏所有贴图", #selector(toggleHidden), icon: pins.isHidden ? "eye" : "eye.slash")
            if pins.hasClickThrough { add("取消所有鼠标穿透", #selector(recoverPins), icon: "cursorarrow") }
            let parent = menu.addItem(withTitle: "贴图（\(pins.count)）", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
            let list = NSMenu()
            for (title, id) in pins.windowItems {
                let item = list.addItem(withTitle: title, action: #selector(focusPin(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id.uuidString
            }
            list.addItem(.separator())
            let close = list.addItem(withTitle: "关闭所有贴图", action: #selector(closePins), keyEquivalent: "")
            close.target = self
            parent.submenu = list
        }
        menu.addItem(.separator())
        add("设置…", #selector(openSettings), icon: "gearshape", key: ",")
        add("快捷键…", #selector(openShortcuts), icon: "keyboard")
        add("退出截一屏", #selector(quit), icon: "power", key: "q")
    }

    private func add(_ title: String, _ action: Selector, icon: String, key: String = "") {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
    }

    @objc private func trigger(_ item: NSMenuItem) {
        if let action = HotkeyAction(rawValue: UInt32(item.tag)) { perform(action) }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .capture: capture.start(.standard)
        case .translate: capture.start(.translate)
        case .paste: if !capture.busy { pins.paste() }
        }
    }

    @objc private func toggleHidden() { pins.setHidden(!pins.isHidden) }
    @objc private func recoverPins() { pins.resetClickThrough() }
    @objc private func closePins() { pins.closeAll() }
    @objc private func openSettings() { settings.show() }
    @objc private func openShortcuts() { settings.show(shortcuts: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func focusPin(_ item: NSMenuItem) {
        if let string = item.representedObject as? String, let id = UUID(uuidString: string) { pins.focus(id) }
    }

    private func showPermission() {
        if CGPreflightScreenCaptureAccess() {
            openCaptureSettings()
            return
        }
        guard permissionAlert == nil else { return }
        let alert = NSAlert()
        alert.messageText = "允许截一屏读取屏幕"
        alert.informativeText = "截图和截图翻译需要 macOS 屏幕录制权限。授权后如系统提示退出，请重新打开截一屏。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "稍后")
        permissionAlert = alert
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        permissionAlert = nil
        if response == .alertFirstButtonReturn {
            if !CGRequestScreenCaptureAccess() { openCaptureSettings() }
        }
    }

    private func openCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "截一屏"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
