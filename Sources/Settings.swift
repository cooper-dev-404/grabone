import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsController {
    private var window: NSWindow?
    private let hotkeys: Hotkeys
    private let state = SettingsWindowState()
    var onPermission: (() -> Void)?
    var onApplyPinSpace: (() -> Void)?

    init(hotkeys: Hotkeys) { self.hotkeys = hotkeys }

    func showTranslation() {
        state.selection = .translation
        show()
    }

    func show(shortcuts: Bool = false) {
        if shortcuts { state.selection = .hotkeys }
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 589, height: 252),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "截一屏 · 偏好设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let view = SettingsView(
            hotkeys: hotkeys, state: state,
            openPermission: { [weak self] in self?.onPermission?() },
            applyPinSpace: { [weak self] in self?.onApplyPinSpace?() },
            close: { [weak window] in window?.performClose(nil) },
            fitHeight: { [weak window] height in
                // Resize after AppKit finishes the hosting view's current layout pass.
                DispatchQueue.main.async {
                    guard let window else { return }
                    var frame = window.frame
                    let previousTop = frame.maxY
                    let height = ceil(height) + 28
                    guard height > 28, abs(height - frame.height) >= 1 else { return }
                    frame.size.height = height
                    frame.origin.y = previousTop - height
                    if let screen = window.screen, frame.minY < screen.visibleFrame.minY {
                        frame.origin.y = screen.visibleFrame.minY
                    }
                    window.setFrame(frame, display: true)
                }
            }
        )
        let container = NSView()
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "截一屏 偏好设置")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        container.addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            hosting.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        window.contentView = container
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .windowBackgroundColor
                : NSColor(srgbRed: 0.942, green: 0.962, blue: 0.981, alpha: 1)
        }
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "常规", interface = "界面", capture = "截图", pin = "贴图"
    case translation = "翻译", output = "输出", hotkeys = "控制", about = "关于"

    var id: Self { self }

    var keys: [String] {
        typealias Key = Preferences.Key
        return switch self {
        case .pin: [Key.allSpaces, Key.scrollZoom, Key.doubleClick, Key.pinOpacity]
        case .translation: [Key.sourceLanguage, Key.targetLanguage]
        case .output: [Key.format, Key.jpegQuality, Key.directory]
        default: []
        }
    }
}

private enum CaptureTab: String, CaseIterable, Identifiable {
    case appearance = "显示", behavior = "行为", keyboard = "按键"
    var id: Self { self }
}

@MainActor
private final class SettingsWindowState: ObservableObject {
    @Published var selection = SettingsSection.general
    @Published var captureTab = CaptureTab.appearance
    @Published var interfaceTab = InterfaceTab.general
    @Published var launches = SMAppService.mainApp.status == .enabled
    @Published var permitted = CGPreflightScreenCaptureAccess()
    @Published var loginError: String?
    @Published var recording: HotkeyAction?
    @Published var shortcutMessage: String?
    @Published var shortcutFailed = false
    var monitor: Any?
}

private struct SettingsView: View {
    @ObservedObject var hotkeys: Hotkeys
    @ObservedObject var state: SettingsWindowState
    let openPermission: () -> Void
    let applyPinSpace: () -> Void
    let close: () -> Void
    let fitHeight: (CGFloat) -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage(Preferences.Key.interfaceFontSize) private var fontSize = 13

    var body: some View {
        ZStack(alignment: .top) {
            page
                .background(panelBackground(inner: false))
                .padding(.top, 10)
            SettingsTabs(values: SettingsSection.allCases, selection: $state.selection,
                         accessibilityName: "设置分类")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 21)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: CGFloat(min(14, max(12, fontSize)))))
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.94))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitHeight($0) }
        .onExitCommand(perform: close)
    }

    @ViewBuilder
    private var page: some View {
        if state.selection == .interface || state.selection == .capture {
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    if state.selection == .interface {
                        InterfacePane(tab: $state.interfaceTab)
                    } else {
                        CapturePane(tab: state.captureTab) { state.selection = .hotkeys }
                    }
                    Spacer(minLength: 0)
                    resetButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 26)
                .padding(.bottom, 21)
                .frame(minHeight: nestedPanelHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(panelBackground(inner: true))
                .padding(.top, 10)
                if state.selection == .interface {
                    SettingsTabs(values: InterfaceTab.allCases, selection: $state.interfaceTab,
                                 accessibilityName: "界面设置", isCompact: true)
                } else {
                    SettingsTabs(values: CaptureTab.allCases, selection: $state.captureTab,
                                 accessibilityName: "截图设置", isCompact: true)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 13) {
                switch state.selection {
                case .general: GeneralPane(openPermission: openPermission, state: state)
                case .pin: PinPane(applyPinSpace: applyPinSpace)
                case .translation: TranslationPane()
                case .output: OutputPane()
                case .hotkeys: HotkeyPane(hotkeys: hotkeys, state: state)
                case .about: AboutPane()
                case .interface, .capture: EmptyView()
                }
                resetButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 26)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nestedPanelHeight: CGFloat {
        switch state.selection {
        case .interface: return 138
        case .capture where state.captureTab == .appearance: return 278
        default: return 195
        }
    }

    private var resetKeys: [String] {
        typealias Key = Preferences.Key
        switch state.selection {
        case .interface:
            return state.interfaceTab == .general ? [Key.accent, Key.interfaceFontSize] : [Key.magnifier, Key.magnifierZoom]
        case .capture:
            switch state.captureTab {
            case .appearance: return [Key.mask, Key.border, Key.anchors, Key.anchorOutline, Key.crosshair, Key.hints]
            case .behavior: return [Key.snap, Key.cursor, Key.excludeOwn]
            case .keyboard: return []
            }
        default: return state.selection.keys
        }
    }

    @ViewBuilder
    private var resetButton: some View {
        if !resetKeys.isEmpty {
            HStack {
                Spacer(minLength: 0)
                Button("恢复默认值") {
                    for key in resetKeys { UserDefaults.standard.removeObject(forKey: key) }
                    if state.selection == .pin { applyPinSpace() }
                }
                .buttonStyle(PreferenceButtonStyle())
            }
        }
    }

    private func panelBackground(inner: Bool) -> some View {
        let shade = scheme == .dark ? (inner ? 0.195 : 0.165) : (inner ? 0.885 : 0.912)
        let shape = RoundedRectangle(cornerRadius: 5)
        return shape.fill(Color(white: shade))
            .overlay(shape.strokeBorder(.primary.opacity(0.06)))
    }
}

private struct PreferenceButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        let fill = scheme == .dark ? Color(white: 0.29) : Color.white
        configuration.label
            .padding(.horizontal, 9)
            .frame(minHeight: 21)
            .background(shape.fill(configuration.isPressed ? Color(nsColor: .selectedControlColor) : fill))
            .overlay(shape.strokeBorder(.primary.opacity(0.16), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.08), radius: 0.7, y: 0.6)
            .contentShape(shape)
    }
}

private struct SettingsTabs<Item: Hashable & RawRepresentable>: View where Item.RawValue == String {
    let values: [Item]
    @Binding var selection: Item
    let accessibilityName: String
    var isCompact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { item in
                let current = selection == item
                Button { selection = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: current ? .medium : .regular))
                        .foregroundStyle(current ? Color.white : Color.primary)
                        .frame(minWidth: isCompact ? 46 : 49, minHeight: 20)
                        .background {
                            if current { RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .systemBlue)) }
                        }
                        .overlay(alignment: .leading) {
                            if let index = values.firstIndex(of: item), index > 0,
                               !current, values[index - 1] != selection {
                                Rectangle().fill(.primary.opacity(0.12)).frame(width: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .background(scheme == .dark ? Color(white: 0.245) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
        .onMoveCommand { direction in
            guard let index = values.firstIndex(of: selection) else { return }
            if direction == .left, index > 0 { selection = values[index - 1] }
            if direction == .right, index + 1 < values.count { selection = values[index + 1] }
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(scheme == .dark ? Color(white: 0.195) : Color(white: 0.90))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.08)))
            }
        }
    }
}

private struct GeneralPane: View {
    let openPermission: () -> Void
    @ObservedObject var state: SettingsWindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("登录时启动截一屏", isOn: Binding(get: { state.launches }, set: setLaunchAtLogin))
                .toggleStyle(.checkbox)
            if let loginError = state.loginError {
                Text(loginError).font(.callout).foregroundStyle(.secondary)
            }
            SettingsGroup("系统权限") {
                HStack(spacing: 8) {
                    Text("屏幕录制")
                    Text(state.permitted ? "已允许" : "待授权")
                        .foregroundStyle(.secondary)
                    Button(state.permitted ? "管理权限…" : "授权…", action: openPermission)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            state.loginError = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置中允许登录项。" : nil
        } catch {
            state.loginError = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        state.launches = status == .enabled || status == .requiresApproval
        state.permitted = CGPreflightScreenCaptureAccess()
    }
}

private enum InterfaceTab: String, CaseIterable, Identifiable {
    case general = "常规", magnifier = "放大镜"
    var id: Self { self }
}

private struct InterfacePane: View {
    @Binding var tab: InterfaceTab
    @AppStorage(Preferences.Key.interfaceFontSize) private var fontSize = 13
    @AppStorage(Preferences.Key.accent) private var accent = "blue"
    @AppStorage(Preferences.Key.magnifier) private var magnifier = true
    @AppStorage(Preferences.Key.magnifierZoom) private var magnifierZoom = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch tab {
            case .general:
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("界面字号")
                        Picker("界面字号", selection: $fontSize) {
                            ForEach([12, 13, 14], id: \.self) { size in
                                Text("系统 \(size) pt").tag(size)
                            }
                        }
                        .labelsHidden()
                        .help("调整偏好设置中的文字大小。")
                    }
                    GridRow {
                        Text("选区颜色")
                        Picker("选区颜色", selection: $accent) {
                            swatch("系统蓝", color: .systemBlue).tag("blue")
                            swatch("青绿", color: .systemTeal).tag("teal")
                            swatch("橙色", color: .systemOrange).tag("orange")
                            swatch("粉红", color: .systemPink).tag("pink")
                        }
                        .labelsHidden()
                        .help("同时设置边框、锚点和放大镜十字线的颜色。")
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            case .magnifier:
                Toggle("框选时显示像素放大镜", isOn: $magnifier)
                    .toggleStyle(.checkbox)
                Picker("放大倍率", selection: $magnifierZoom) {
                    ForEach([5, 7, 9], id: \.self) { Text("\($0)×").tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!magnifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func swatch(_ title: String, color: NSColor) -> some View {
        let image = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        return Label {
            Text(title)
        } icon: {
            Image(nsImage: image).renderingMode(.original)
        }
        .labelStyle(.titleAndIcon)
    }
}

private struct CapturePane: View {
    let tab: CaptureTab
    let showControls: () -> Void
    @AppStorage(Preferences.Key.snap) private var snap = true
    @AppStorage(Preferences.Key.crosshair) private var crosshair = false
    @AppStorage(Preferences.Key.hints) private var hints = true
    @AppStorage(Preferences.Key.anchors) private var anchors = true
    @AppStorage(Preferences.Key.anchorOutline) private var anchorOutline = -1
    @AppStorage(Preferences.Key.cursor) private var cursor = false
    @AppStorage(Preferences.Key.excludeOwn) private var excludeOwn = true
    @AppStorage(Preferences.Key.mask) private var mask = 0.46
    @AppStorage(Preferences.Key.border) private var border = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch tab {
            case .appearance:
                HStack(spacing: 6) {
                    Text("边框宽度")
                    TextField("边框宽度", value: Binding(
                        get: { border },
                        set: { border = min(3, max(0.5, ($0 * 2).rounded() / 2)) }
                    ), format: .number.precision(.fractionLength(0...1)))
                        .controlSize(.small)
                        .frame(width: 32)
                        .multilineTextAlignment(.center)
                    Stepper("调整边框宽度", value: $border, in: 0.5...3, step: 0.5)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityValue(Text("\(border.formatted()) 点"))
                    Text("点")
                }
                HStack(spacing: 6) {
                    Text("遮罩深度")
                    Slider(value: Binding(get: { mask }, set: { mask = ($0 * 100).rounded() / 100 }),
                           in: 0.15...0.80) { Text("遮罩深度") }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 112)
                    Text(mask.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                Toggle("显示选区锚点", isOn: $anchors)
                HStack(spacing: 6) {
                    Text("锚点描边颜色")
                    ColorPicker("锚点描边颜色", selection: outlineColor, supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.small)
                }
                .disabled(!anchors)
                Toggle("显示全屏十字线", isOn: $crosshair)
                Toggle("显示框选操作提示", isOn: $hints)
            case .behavior:
                Toggle("自动吸附到窗口", isOn: $snap)
                Toggle("截图中包含鼠标指针", isOn: $cursor)
                Toggle("截图时隐藏截一屏的窗口及贴图", isOn: $excludeOwn)
            case .keyboard:
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow { Text("切换窗口吸附"); Text("Tab") }
                    GridRow { Text("移动选区 / 调整宽高"); Text("方向键 / ⇧方向键") }
                    GridRow { Text("复制 / 保存"); Text("Return、⌘C / ⌘S") }
                    GridRow { Text("贴图 / 翻译"); Text("P / T") }
                }
                Button("修改全局快捷键…", action: showControls)
                    .controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outlineColor: Binding<Color> {
        Binding(get: { Color(nsColor: Preferences.anchorOutlineColor(anchorOutline)) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
            anchorOutline = (byte(rgb.redComponent) << 16) | (byte(rgb.greenComponent) << 8) | byte(rgb.blueComponent)
        })
    }
}

private struct PinPane: View {
    let applyPinSpace: () -> Void
    @AppStorage(Preferences.Key.allSpaces) private var allSpaces = true
    @AppStorage(Preferences.Key.scrollZoom) private var scrollZoom = true
    @AppStorage(Preferences.Key.doubleClick) private var doubleClick = "toggle"
    @AppStorage(Preferences.Key.pinOpacity) private var opacity = 1.0

    var body: some View {
        SettingsGroup("窗口") {
            Toggle("在所有桌面空间显示", isOn: $allSpaces)
                .onChange(of: allSpaces) { _, _ in applyPinSpace() }
            Toggle("滚动缩放", isOn: $scrollZoom)
            Picker("双击贴图", selection: $doubleClick) {
                Text("切换原图与译文 / 普通贴图恢复大小").tag("toggle")
                Text("关闭贴图").tag("close")
            }
            .fixedSize()
            LabeledContent("新贴图不透明度") {
                HStack(spacing: 9) {
                    Slider(value: $opacity, in: 0.25...1.0) { Text("新贴图不透明度") }
                        .labelsHidden().frame(width: 156)
                    Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().frame(width: 39, alignment: .trailing)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct TranslationPane: View {
    @AppStorage(Preferences.Key.sourceLanguage) private var source = "auto"
    @AppStorage(Preferences.Key.targetLanguage) private var target = "zh-Hans"
    private let languages = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"),
        ("es", "Español"), ("de", "Deutsch"), ("it", "Italiano"), ("pt", "Português")
    ]

    var body: some View {
        SettingsGroup("语言") {
            Picker("源语言", selection: $source) {
                Text("自动识别").tag("auto")
                ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
            }.fixedSize()
            Picker("目标语言", selection: $target) {
                ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
            }.fixedSize()
        }
        SettingsGroup("原位显示") {
            LabeledContent("翻译服务", value: "Apple 系统翻译")
            Text("首次使用某个语种可能需要下载语言包。贴图中可切换原图与译文，复制和保存图片时保留原图内容。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OutputPane: View {
    @AppStorage(Preferences.Key.format) private var format = "png"
    @AppStorage(Preferences.Key.jpegQuality) private var quality = 0.93
    @AppStorage(Preferences.Key.directory) private var directory = ""

    var body: some View {
        SettingsGroup("保存文件") {
            Picker("图片格式", selection: $format) {
                Text("PNG").tag("png")
                Text("JPEG").tag("jpeg")
            }
            .pickerStyle(.segmented).fixedSize()
            if format == "jpeg" {
                LabeledContent("JPEG 质量") {
                    Slider(value: $quality, in: 0.45...1) { Text("JPEG 质量") }
                        .labelsHidden().frame(width: 150)
                    Text(quality.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }
            }
            LabeledContent("默认文件夹") {
                HStack {
                    Text(directory.isEmpty ? "系统上次使用的位置" : URL(fileURLWithPath: directory).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(directory)
                    Button("选择…", action: chooseDirectory)
                    if !directory.isEmpty { Button("清除") { directory = "" } }
                }
            }
        }
        SettingsGroup("剪贴板") { LabeledContent("复制图片", value: "PNG / TIFF") }
    }

    private func chooseDirectory() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选取"
        if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url { directory = url.path }
        }
    }
}

private struct HotkeyPane: View {
    @ObservedObject var hotkeys: Hotkeys
    @ObservedObject var state: SettingsWindowState

    var body: some View {
        SettingsGroup("全局快捷键") {
            ForEach(HotkeyAction.allCases) { action in
                HStack(spacing: 9) {
                    Label(action.title, systemImage: action.symbol)
                        .frame(width: 136, alignment: .leading)
                    recordButton(action)
                    Button("恢复默认") {
                        stopRecording()
                        let result = hotkeys.change(action.standard, action: action)
                        showMessage(result ? "\(action.title)已恢复默认。" : "默认快捷键已被占用。", failed: !result)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("恢复\(action.title)默认快捷键")
                    if hotkeys.conflicts.contains(action) {
                        Label("注册失败", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let message = state.shortcutMessage {
                Text(message).font(.callout)
                    .foregroundStyle(state.shortcutFailed ? Color.red : Color.secondary)
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let target = note.object as? NSWindow, target === recordingWindow { stopRecording() }
        }

        Text("点快捷键开始录入，支持 ⌘F1 等功能键组合，Esc 取消。键盘顶排控制亮度或音量时，录入请一并按住 Fn。")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var recordingWindow: NSWindow? { NSApp.windows.first { $0.title == "截一屏 · 偏好设置" } }

    private func recordButton(_ action: HotkeyAction) -> some View {
        let active = state.recording == action
        let label = (hotkeys.bindings[action] ?? action.standard).label
        return Button {
            if active { stopRecording(); return }
            startRecording(action)
        } label: {
            Text(active ? "请按快捷键…" : label)
                .monospaced()
                .frame(minWidth: 114)
        }
        .buttonStyle(.bordered)
        .tint(active ? Color.accentColor : nil)
        .accessibilityLabel("\(action.title)快捷键")
        .accessibilityValue(active ? "正在录入" : label)
    }

    private func startRecording(_ action: HotkeyAction) {
        stopRecording()
        guard let window = recordingWindow else { return }
        window.makeKey()
        hotkeys.suspendForRecording()
        state.recording = action
        showMessage("正在录入\(action.title)的快捷键。", failed: false)
        state.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window || NSApp.keyWindow === window else { return event }
            if event.keyCode == 53 {
                stopRecording()
                showMessage("已取消录入。", failed: false)
                return nil
            }
            guard !event.isARepeat else { return nil }
            guard let shortcut = Shortcut(event: event) else {
                showMessage("请按功能键，或用 ⌃、⌥、⌘ 搭配字母、数字或符号。", failed: true)
                return nil
            }
            if hotkeys.change(shortcut, action: action) {
                stopRecording()
                showMessage("\(action.title)已设为 \(shortcut.label)。", failed: false)
            } else {
                showMessage("\(shortcut.label) 已被占用，请尝试其他组合，或按 Esc 取消。", failed: true)
            }
            return nil
        }
    }

    private func stopRecording() {
        guard state.recording != nil else { return }
        if let monitor = state.monitor { NSEvent.removeMonitor(monitor) }
        state.monitor = nil
        state.recording = nil
        hotkeys.resumeAfterRecording()
    }

    private func showMessage(_ message: String, failed: Bool) {
        state.shortcutFailed = failed
        state.shortcutMessage = message
    }
}

private struct AboutPane: View {
    var body: some View {
        SettingsGroup("应用信息") {
            LabeledContent("截一屏", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Text("截图、贴图与原位翻译").font(.callout).foregroundStyle(.secondary)
        }
    }
}
