import AppKit
import Carbon
import ImageIO
import UniformTypeIdentifiers

@main
struct Regression {
    @MainActor
    static func main() async throws {
        try checkShortcuts()
        let image = makeFixture()
        let full = CGSize(width: 300, height: 120)
        let selection = CGRect(x: 12.5, y: 7.5, width: 125, height: 55)
        precondition(ImageGeometry.pixelRect(selection, in: full, image: image) ==
                     CGRect(x: 25, y: 15, width: 250, height: 110))
        precondition(ImageGeometry.pixelRect(CGRect(x: -12, y: 20, width: 13, height: 20), in: full, image: image) ==
                     CGRect(x: 0, y: 40, width: 2, height: 40))
        precondition(ImageGeometry.pixelRect(CGRect(x: 320, y: 0, width: 5, height: 5), in: full, image: image) == nil)
        print("PASS Retina 裁剪、越界裁剪")

        let recognized = try ScreenshotOCR.recognize(image, language: "en")
        guard let line = recognized.first(where: { $0.text.contains("Hello from the screenshot") }) else {
            fatalError("OCR fixture not detected: \(recognized.map(\.text))")
        }
        let top = line.displayRect(in: CGRect(x: 15, y: 20, width: 300, height: 120))
        precondition(top.minY < 85 && top.minY > 25 && top.minX >= 15)
        print("PASS Vision 英文 OCR 及屏幕坐标回映")

        Preferences.configure()
        let translator = OverlayTranslation(image: image)
        translator.start()
        translator.cancel()
        try await Task.sleep(for: .milliseconds(250))
        precondition(translator.phase == .stopped && translator.job == nil && translator.lines.isEmpty)
        print("PASS 停止翻译后迟到的识别结果不会重启任务")

        let translations = [TranslatedLine(source: line, text: "截图中的问候",
                                           background: TranslatedLine.sampleBackground(for: line, from: image))]
        let document = CaptureDocument(original: image, logicalSize: full)
        let before = CaptureDocument.encoded(document.output, format: .png)!
        let context = newContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        translations[0].draw(in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        let overlay = CaptureDocument.encoded(context.makeImage()!, format: .png)!
        precondition(overlay != before)
        precondition(CaptureDocument.encoded(document.output, format: .png) == before)
        precondition(CaptureDocument.encoded(document.original, format: .png) == before)
        print("PASS 译文视图与原图 PNG 的二进制隔离")

        var marked = document
        marked.annotations = [Mark(tool: .arrow, origin: CGPoint(x: 15, y: 10),
                                   points: [CGPoint(x: 40, y: 22)], color: .systemRed, width: 3)]
        precondition(CaptureDocument.encoded(marked.output, format: .png) != before)
        precondition(CaptureDocument.encoded(marked.original, format: .png) == before)
        let jpeg = CaptureDocument.encoded(marked.output, format: .jpeg)!
        guard let decoded = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let roundtrip = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else {
            fatalError("JPEG export unreadable")
        }
        precondition(roundtrip.width == image.width && roundtrip.height == image.height)
        print("PASS 标注合成、原图保留、JPEG 导出尺寸")
    }

    private static func checkShortcuts() throws {
        let f1 = String(UnicodeScalar(NSF1FunctionKey)!)
        func event(code: Int, key: String, modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: 0, context: nil, characters: key,
                             charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: UInt16(code))!
        }
        let shortcut = Shortcut(event: event(code: kVK_F1, key: f1, modifiers: [.command, .function]))!
        precondition(shortcut.label == "⌘F1" && shortcut.key == f1)
        precondition(shortcut.carbonFlags == UInt32(cmdKey))
        let bareF1 = Shortcut(event: event(code: kVK_F1, key: f1, modifiers: [.function]))
        precondition(bareF1?.label == "F1")
        precondition(Shortcut(event: event(code: kVK_F1, key: f1, modifiers: [.command], repeatKey: true)) == nil)
        precondition(Shortcut(event: event(code: kVK_ANSI_A, key: "a", modifiers: [.shift])) == nil)
        let legacy = try JSONEncoder().encode(HotkeyAction.capture.standard)
        let decoded = try JSONDecoder().decode(Shortcut.self, from: legacy)
        precondition(decoded.label == "⌃⌥A")
        print("PASS ⌘F1、Fn 修饰过滤、单独功能键、旧快捷键配置")
    }

    private static func makeFixture() -> CGImage {
        let context = newContext(width: 600, height: 240)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 240))
        context.translateBy(x: 0, y: 240)
        context.scaleBy(x: 1, y: -1)
        drawText("Hello from the screenshot", in: CGRect(x: 42, y: 35, width: 520, height: 50),
                 font: .systemFont(ofSize: 30, weight: .semibold), color: .black, context: context)
        drawText("Open the settings window.", in: CGRect(x: 42, y: 112, width: 520, height: 50),
                 font: .systemFont(ofSize: 26), color: .black, context: context)
        return context.makeImage()!
    }

    private static func newContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}
