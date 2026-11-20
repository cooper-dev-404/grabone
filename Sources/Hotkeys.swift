import AppKit
import Carbon
import Combine

enum HotkeyAction: UInt32, CaseIterable, Identifiable {
    case capture = 1, translate, paste
    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .capture: "区域截图"
        case .translate: "截图翻译"
        case .paste: "剪贴板贴图"
        }
    }

    var symbol: String {
        switch self {
        case .capture: "viewfinder"
        case .translate: "translate"
        case .paste: "pin"
        }
    }

    var standard: Shortcut {
        switch self {
        case .capture: Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: [.control, .option], key: "a")
        case .translate: Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: [.control, .option], key: "t")
        case .paste: Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: [.control, .option], key: "p")
        }
    }
}

struct Shortcut: Equatable, Codable {
    let keyCode: UInt32
    private let flags: UInt
    let key: String

    private static let functionCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].map(UInt32.init)

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.flags = modifiers.intersection([.control, .option, .shift, .command]).rawValue
        self.key = key
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }

    init?(event: NSEvent) {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let code = UInt32(event.keyCode)
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if let index = Self.functionCodes.firstIndex(of: code),
           let scalar = UnicodeScalar(NSF1FunctionKey + index) {
            self.init(keyCode: code, modifiers: modifiers, key: String(scalar))
            return
        }
        guard !modifiers.intersection([.control, .option, .command]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }),
              key.unicodeScalars.allSatisfy({ !(0xE000...0xF8FF).contains($0.value) })
        else { return nil }
        self.init(keyCode: code, modifiers: modifiers, key: key)
    }

    var label: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
        ]
        let name = Self.functionCodes.firstIndex(of: keyCode).map { "F\($0 + 1)" } ?? key.uppercased()
        return symbols.compactMap { modifiers.contains($0.0) ? $0.1 : nil }.joined() + name
    }

    var carbonFlags: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

@MainActor
final class Hotkeys: ObservableObject {
    private static let signature: OSType = 0x47726231
    private var handler: EventHandlerRef?
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    @Published private(set) var bindings: [HotkeyAction: Shortcut] = [:]
    @Published private(set) var conflicts: Set<HotkeyAction> = []
    var onPress: ((HotkeyAction) -> Void)?
    private var suspended = false

    func install() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x47726231, let action = HotkeyAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.onPress?(action) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for action in HotkeyAction.allCases {
            let shortcut = UserDefaults.standard.data(forKey: storageKey(action))
                .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? action.standard
            bindings[action] = shortcut
            if installed != noErr || !register(shortcut, action: action) { conflicts.insert(action) }
        }
    }

    @discardableResult
    func change(_ shortcut: Shortcut, action: HotkeyAction) -> Bool {
        guard !bindings.contains(where: { $0.key != action && $0.value.keyCode == shortcut.keyCode &&
            $0.value.carbonFlags == shortcut.carbonFlags }) else { return false }
        let old = bindings[action] ?? action.standard
        if old == shortcut, refs[action] != nil { return true }
        // Reserve the replacement before giving up the current combination.
        let previous = refs[action]
        guard handler != nil, register(shortcut, action: action) else { return false }
        if let previous { UnregisterEventHotKey(previous) }
        bindings[action] = shortcut
        conflicts.remove(action)
        if let value = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(value, forKey: storageKey(action))
        }
        return true
    }

    func suspendForRecording() {
        guard !suspended else { return }
        suspended = true
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func resumeAfterRecording() {
        guard suspended else { return }
        suspended = false
        for action in HotkeyAction.allCases {
            guard refs[action] == nil, let shortcut = bindings[action] else { continue }
            if handler != nil, register(shortcut, action: action) { conflicts.remove(action) }
            else { conflicts.insert(action) }
        }
    }

    func uninstall() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(_ shortcut: Shortcut, action: HotkeyAction) -> Bool {
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonFlags, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[action] = ref
        return true
    }

    private func storageKey(_ action: HotkeyAction) -> String { "shortcut.\(action.rawValue)" }
}
