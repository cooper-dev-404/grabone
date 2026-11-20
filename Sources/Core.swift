import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Preferences {
    enum Key {
        static let snap = "capture.snapWindows"
        static let magnifier = "capture.magnifier"
        static let magnifierZoom = "capture.magnifierZoom"
        static let anchors = "capture.anchors"
        static let anchorOutline = "capture.anchorOutlineRGB"
        static let crosshair = "capture.crosshair"
        static let hints = "capture.hints"
        static let cursor = "capture.cursor"
        static let excludeOwn = "capture.excludeOwnWindows"
        static let mask = "capture.maskOpacity"
        static let border = "capture.borderWidth"
        static let accent = "capture.accent"
        static let interfaceFontSize = "settings.fontSize"
        static let allSpaces = "pin.allSpaces"
        static let scrollZoom = "pin.scrollZoom"
        static let doubleClick = "pin.doubleClick"
        static let pinOpacity = "pin.opacity"
        static let format = "export.format"
        static let jpegQuality = "export.jpegQuality"
        static let directory = "export.directory"
        static let sourceLanguage = "translation.source"
        static let targetLanguage = "translation.target"
    }

    static let values: [String: Any] = [
        Key.snap: true, Key.magnifier: true, Key.magnifierZoom: 7, Key.anchors: true, Key.crosshair: false,
        Key.anchorOutline: -1, Key.interfaceFontSize: 13,
        Key.hints: true, Key.cursor: false, Key.excludeOwn: true, Key.mask: 0.46,
        Key.border: 1.0, Key.accent: "blue", Key.allSpaces: true, Key.scrollZoom: true,
        Key.doubleClick: "toggle", Key.pinOpacity: 1.0, Key.format: "png", Key.jpegQuality: 0.93,
        Key.directory: "", Key.sourceLanguage: "auto", Key.targetLanguage: "zh-Hans"
    ]

    static func configure() { UserDefaults.standard.register(defaults: values) }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func number(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static var accent: NSColor {
        switch string(Key.accent) {
        case "teal": .systemTeal
        case "orange": .systemOrange
        case "pink": .systemPink
        default: .systemBlue
        }
    }

    static func anchorOutlineColor(_ rgb: Int) -> NSColor {
        guard (0...0xffffff).contains(rgb) else { return accent }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

enum ImageGeometry {
    static func pixelRect(_ rect: CGRect, in size: CGSize, image: CGImage) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let selection = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !selection.isNull, selection.width > 0, selection.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / size.width
        let scaleY = CGFloat(image.height) / size.height
        return CGRect(x: selection.minX * scaleX, y: selection.minY * scaleY,
                      width: selection.width * scaleX, height: selection.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    static func fit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}

func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}

func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color])
}

enum MarkTool: String, CaseIterable {
    case box, ellipse, arrow, line, pen, highlighter, mosaic, text

    var info: (title: String, symbol: String) {
        switch self {
        case .box: ("矩形", "rectangle")
        case .ellipse: ("椭圆", "circle")
        case .arrow: ("箭头", "arrow.up.right")
        case .line: ("直线", "line.diagonal")
        case .pen: ("画笔", "pencil")
        case .highlighter: ("荧光笔", "highlighter")
        case .mosaic: ("马赛克", "checkerboard.rectangle")
        case .text: ("文字", "textformat")
        }
    }
}

struct Mark {
    let tool: MarkTool
    let origin: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var text = ""

    private var end: CGPoint { points.last ?? origin }
    private var rect: CGRect {
        CGRect(x: min(origin.x, end.x), y: min(origin.y, end.y),
               width: abs(end.x - origin.x), height: abs(end.y - origin.y))
    }

    func draw(in context: CGContext, source: CGImage, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(color.cgColor)
        switch tool {
        case .box: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .line:
            context.move(to: origin)
            context.addLine(to: end)
            context.strokePath()
        case .arrow:
            let angle = atan2(end.y - origin.y, end.x - origin.x)
            let length = min(max(width * 4, 8), hypot(end.x - origin.x, end.y - origin.y))
            context.move(to: origin)
            context.addLine(to: end)
            context.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
            context.strokePath()
        case .pen, .highlighter:
            guard !points.isEmpty else { return }
            if tool == .highlighter {
                context.setStrokeColor(color.withAlphaComponent(0.38).cgColor)
                context.setLineWidth(max(8, width * 4))
            }
            context.addLines(between: [origin] + points)
            context.strokePath()
        case .mosaic:
            guard let pixelRect = ImageGeometry.pixelRect(rect, in: size, image: source),
                  let region = source.cropping(to: pixelRect) else { return }
            let blockSize = max(6, width * 4)
            let lowWidth = max(1, Int((rect.width / blockSize).rounded(.up)))
            let lowHeight = max(1, Int((rect.height / blockSize).rounded(.up)))
            guard let low = CGContext(data: nil, width: lowWidth, height: lowHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            low.interpolationQuality = .medium
            low.draw(region, in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight))
            if let pattern = low.makeImage() {
                context.interpolationQuality = .none
                drawImage(pattern, in: rect, context: context)
            }
        case .text:
            let font = NSFont.systemFont(ofSize: 10 + width * 3, weight: .semibold)
            drawText(text, in: CGRect(x: origin.x, y: origin.y,
                                      width: max(0, size.width - origin.x), height: max(0, size.height - origin.y)),
                     font: font, color: color, context: context)
        }
    }
}

struct CaptureDocument {
    let original: CGImage
    let logicalSize: CGSize
    var annotations: [Mark] = []

    var output: CGImage {
        guard !annotations.isEmpty,
              let context = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return original }
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        context.translateBy(x: 0, y: CGFloat(original.height))
        context.scaleBy(x: CGFloat(original.width) / logicalSize.width,
                        y: -CGFloat(original.height) / logicalSize.height)
        for mark in annotations { mark.draw(in: context, source: original, size: logicalSize) }
        return context.makeImage() ?? original
    }

    static func encoded(_ image: CGImage, format: UTType, quality: Double = 0.93) -> Data? {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(encoder, image, format == .jpeg ? options : nil)
        return CGImageDestinationFinalize(encoder) ? data as Data : nil
    }

    @MainActor
    static func copy(_ image: CGImage) {
        guard let data = encoded(image, format: .png) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    @MainActor
    static func save(_ image: CGImage, owner: NSWindow? = nil, failure: @escaping (String) -> Void) {
        let format: UTType = Preferences.string(Preferences.Key.format) == "jpeg" ? .jpeg : .png
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.allowedContentTypes = [format]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "截图 " + formatter.string(from: Date()) + "." + (format.preferredFilenameExtension ?? "png")
        let directory = Preferences.string(Preferences.Key.directory)
        if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = encoded(image, format: format, quality: Preferences.number(Preferences.Key.jpegQuality)) else {
                failure("无法编码截图。")
                return
            }
            do { try data.write(to: url, options: .atomic) }
            catch { failure("无法保存截图。\n" + error.localizedDescription) }
        }
        if let owner, owner.isVisible {
            panel.beginSheetModal(for: owner, completionHandler: complete)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: complete)
        }
    }
}
