import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import Vision

struct OCRLine: Sendable {
    let id: String
    let text: String
    let box: CGRect

    func displayRect(in image: CGRect) -> CGRect {
        CGRect(x: image.minX + box.minX * image.width,
               y: image.minY + (1 - box.maxY) * image.height,
               width: box.width * image.width, height: box.height * image.height)
    }
}

struct TranslatedLine {
    let source: OCRLine
    let text: String
    let background: NSColor

    func draw(in imageRect: CGRect, context: CGContext) {
        let rect = source.displayRect(in: imageRect)
        guard rect.width > 1, rect.height > 1 else { return }
        let padding = max(0.5, rect.height * 0.13)
        let cover = rect.insetBy(dx: -padding, dy: -padding).intersection(imageRect)
        context.setFillColor(background.cgColor)
        context.fill(cover)

        let brightness = (background.redComponent * 0.2126) + (background.greenComponent * 0.7152)
            + (background.blueComponent * 0.0722)
        let foreground: NSColor = brightness > 0.54 ? .black : .white
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let initial = rect.height * 0.94
        let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: initial)]).width
        let shrink = min(1, (cover.width - 0.6) / max(textWidth, 1))
        let size = max(initial * 0.58, initial * shrink)
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph
        ]
        let textRect = CGRect(x: rect.minX, y: rect.midY - (font.ascender - font.descender) / 2,
                              width: max(1, cover.maxX - rect.minX),
                              height: font.ascender - font.descender + font.leading + 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func sampleBackground(for line: OCRLine, from image: CGImage) -> NSColor {
        let area = line.displayRect(in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let stripHeight = max(1, area.height * 0.14)
        let y = area.minY >= stripHeight ? area.minY - stripHeight : area.maxY
        let strip = CGRect(x: area.minX, y: y, width: max(1, area.width), height: stripHeight)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !strip.isNull, let sample = image.cropping(to: strip) else { return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
        var pixel: [UInt8] = [255, 255, 255, 255]
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.interpolationQuality = .high
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

enum ScreenshotOCR {
    struct Reading {
        let lines: [OCRLine]
        let allConfident: Bool
    }

    static func read(_ image: CGImage, language: String, using request: VNRecognizeTextRequest) throws -> Reading {
        let fast = request.recognitionLevel == .fast
        let supported = try request.supportedRecognitionLanguages()
        if language == "auto" {
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = supported
        } else if let match = supported.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame })
                    ?? supported.first(where: { $0.lowercased().hasPrefix(language.lowercased() + "-") }) {
            request.recognitionLanguages = [match]
        } else if fast {
            return Reading(lines: [], allConfident: false)
        }
        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        let observations = request.results ?? []
        let lines = observations.enumerated().compactMap { index, observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if fast {
                guard candidate.confidence >= 0.45,
                      text.rangeOfCharacter(from: .illegalCharacters) == nil,
                      !text.contains("�") else { return nil }
                if language == "auto" {
                    // The fast model can turn unsupported scripts into plausible punctuation.
                    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                    guard letters.count >= 3, letters.count * 2 >= text.count,
                          let guess = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue,
                          supported.contains(where: { $0 == guess || $0.hasPrefix(guess + "-") })
                    else { return nil }
                }
            }
            return OCRLine(id: String(index), text: text, box: observation.boundingBox)
        }
        return Reading(lines: lines, allConfident: !lines.isEmpty && lines.count == observations.count)
    }

    static func recognize(_ image: CGImage, language: String) throws -> [OCRLine] {
        let fast = VNRecognizeTextRequest()
        fast.recognitionLevel = .fast
        let first = try? read(image, language: language, using: fast)
        if language != "auto", let first, first.allConfident { return first.lines }
        let accurate = VNRecognizeTextRequest()
        accurate.recognitionLevel = .accurate
        do { return try read(image, language: language, using: accurate).lines }
        catch {
            if let first, !first.lines.isEmpty { return first.lines }
            throw error
        }
    }
}

@MainActor
final class OverlayTranslation: ObservableObject {
    enum Phase: Equatable {
        case idle, recognizing, translating, checking(Int), languagePack, sameLanguage, stopped, ready(Int), failed(String)

        var busy: Bool {
            switch self {
            case .recognizing, .translating, .checking, .languagePack: true
            default: false
            }
        }

        var caption: String {
            switch self {
            case .idle: "原始截图"
            case .stopped: "已停止翻译"
            case .recognizing: "正在识别文字…"
            case .translating: "正在翻译…"
            case .checking(let count): "已显示 \(count) 处 · 核对中"
            case .languagePack: "正在准备语言包…"
            case .sameLanguage: "原文已是目标语言"
            case .ready(let count): "\(count) 处译文"
            case .failed(let reason): reason
            }
        }
    }

    struct Job {
        let id = UUID()
        let source: String?
        let target: String
        let rows: [OCRLine]

        var configuration: TranslationSession.Configuration {
            TranslationSession.Configuration(source: source.map { Locale.Language(identifier: $0) },
                                             target: Locale.Language(identifier: target))
        }
    }

    private struct TextKey: Hashable {
        let language: String?
        let target: String
        let original: String
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var job: Job?
    private(set) var lines: [TranslatedLine] = []
    private(set) var recognized: [OCRLine] = []
    var onChange: (() -> Void)?
    private let image: CGImage
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var request: VNRecognizeTextRequest?
    private var session: TranslationSession?
    private var generation = UUID()
    private var queue: [Job] = []
    private var source = "auto"
    private var target = "zh-Hans"
    private var preview = false
    private var sourceHasWords = false
    private var groupErrors: [String: String] = [:]
    private var completeRecognition: (language: String, rows: [OCRLine])?
    // Scoped to this pinned image, including its source and destination language.
    private var cache: [TextKey: String] = [:]
    private var pageKeys: [String: TextKey] = [:]

    init(image: CGImage) { self.image = image }

    func cancel() {
        stopWork()
        setPhase(.stopped)
    }

    private func stopWork() {
        generation = UUID()
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
        task = nil
        request?.cancel()
        request = nil
        if #available(macOS 26, *) { session?.cancel() }
        session = nil
        job = nil
        queue = []
    }

    func start() {
        stopWork()
        lines = []
        recognized = []
        groupErrors = [:]
        source = Preferences.string(Preferences.Key.sourceLanguage)
        target = Preferences.string(Preferences.Key.targetLanguage)
        if let cached = completeRecognition, cached.language == source {
            translatePage(cached.rows, provisional: false)
        } else {
            startReading(fast: true)
        }
    }

    private func startReading(fast: Bool) {
        let token = generation
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        self.request = request
        setPhase(lines.isEmpty ? .recognizing : .checking(lines.count))
        armTimeout(seconds: fast ? 8 : 90, message: "文字识别超时，点重试")
        let image = image
        let language = source
        let worker = Task.detached(priority: .userInitiated) {
            try ScreenshotOCR.read(image, language: language, using: request)
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: { worker.cancel() }
            guard let self, token == generation, !Task.isCancelled else { return }
            self.request = nil
            switch result {
            case .success(let reading) where !reading.lines.isEmpty:
                let provisional = fast && (source == "auto" || !reading.allConfident)
                if !provisional { completeRecognition = (source, reading.lines) }
                translatePage(reading.lines, provisional: provisional)
            case _ where fast:
                startReading(fast: false)
            case .success:
                if lines.isEmpty { fail("未识别到文字，请扩大选区") }
                else { fail("精确识别未检出文字，已保留快译") }
            case .failure:
                fail(lines.isEmpty ? "系统文字识别失败，点重试" : "精确识别失败，已保留快译")
            }
        }
    }

    private func translatePage(_ rows: [OCRLine], provisional: Bool) {
        preview = provisional
        recognized = rows
        let dominant = source == "auto"
            ? NLLanguageRecognizer.dominantLanguage(for: rows.map(\.text).joined(separator: " "))?.rawValue
            : source
        pageKeys = [:]
        var groups: [String: [OCRLine]] = [:]
        var order: [String] = []
        var distinct = Set<TextKey>()
        sourceHasWords = false
        for row in rows {
            guard row.text.rangeOfCharacter(from: .letters) != nil else { continue }
            sourceHasWords = true
            var language = dominant
            if source == "auto", row.text.count >= 6 {
                let detector = NLLanguageRecognizer()
                detector.processString(row.text)
                if let identified = detector.dominantLanguage,
                   (detector.languageHypotheses(withMaximum: 1)[identified] ?? 0) >= 0.75 {
                    language = identified.rawValue
                }
            }
            guard language != target else { continue }
            let key = TextKey(language: language, target: target, original: row.text)
            pageKeys[row.id] = key
            guard cache[key] == nil, distinct.insert(key).inserted else { continue }
            let group = language ?? ""
            guard groupErrors[group] == nil else { continue }
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(row)
        }
        queue = order.map { Job(source: $0.isEmpty ? nil : $0, target: target, rows: groups[$0]!) }
        updateLines(keepPrevious: true)
        nextGroup()
    }

    private func nextGroup() {
        session = nil
        job = nil
        if !queue.isEmpty {
            setPhase(lines.isEmpty ? .translating : .checking(lines.count))
            armTimeout(seconds: 35, message: "翻译服务响应超时，点重试")
            job = queue.removeFirst()
            return
        }
        if preview {
            if lines.isEmpty, let error = groupErrors.values.first { fail(error); return }
            startReading(fast: false)
        } else {
            watchdog?.cancel()
            updateLines(keepPrevious: false)
            if !sourceHasWords { fail("选区只有数字或符号") }
            else if pageKeys.isEmpty { setPhase(.sameLanguage) }
            else if lines.count < pageKeys.count {
                let error = groupErrors.values.first ?? "部分文字未返回译文，点重试"
                fail(error)
            }
            else { setPhase(.ready(lines.count)) }
        }
    }

    func translate(_ item: Job, using session: TranslationSession) async {
        guard job?.id == item.id, self.session == nil else { return }
        self.session = session
        do {
            if let sourceLanguage = item.source {
                let availability = await LanguageAvailability().status(from: Locale.Language(identifier: sourceLanguage),
                                                                        to: Locale.Language(identifier: item.target))
                guard job?.id == item.id, !Task.isCancelled else { return }
                switch availability {
                case .unsupported: skipGroup("系统不支持这组语言，请调整翻译设置"); return
                case .supported:
                    setPhase(.languagePack)
                    armTimeout(seconds: 300, message: "语言包尚未就绪，点重试")
                    try await session.prepareTranslation()
                    guard job?.id == item.id, !Task.isCancelled else { return }
                default: break
                }
            }
            setPhase(lines.isEmpty ? .translating : .checking(lines.count))
            armTimeout(seconds: 35, message: "翻译服务响应超时，点重试")
            for start in stride(from: 0, to: item.rows.count, by: 32) {
                let batch = item.rows[start..<min(start + 32, item.rows.count)].map {
                    TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
                }
                let responses = try await session.translations(from: batch)
                guard job?.id == item.id, !Task.isCancelled else { return }
                for response in responses {
                    guard let id = response.clientIdentifier, let key = pageKeys[id],
                          !response.targetText.isEmpty else { continue }
                    cache[key] = response.targetText
                }
                updateLines(keepPrevious: true)
                onChange?()
                armTimeout(seconds: 35, message: "翻译服务响应超时，点重试")
            }
            nextGroup()
        } catch {
            guard job?.id == item.id else { return }
            switch error {
            case TranslationError.unsupportedSourceLanguage, TranslationError.unableToIdentifyLanguage:
                skipGroup("无法确定源语言，请在翻译设置中指定")
            case TranslationError.unsupportedTargetLanguage, TranslationError.unsupportedLanguagePairing:
                skipGroup("系统不支持这组翻译语言，请调整设置")
            default: skipGroup(phase == .languagePack ? "语言包未准备好，点重试" : "翻译中断，点重试")
            }
        }
    }

    private func skipGroup(_ detail: String) {
        guard let job else { return }
        groupErrors[job.source ?? ""] = detail
        nextGroup()
    }

    private func updateLines(keepPrevious: Bool) {
        let updated = recognized.compactMap { row -> TranslatedLine? in
            guard let key = pageKeys[row.id], let text = cache[key] else { return nil }
            return TranslatedLine(source: row, text: text, background: TranslatedLine.sampleBackground(for: row, from: image))
        }
        if !keepPrevious || !updated.isEmpty { lines = updated }
    }

    private func armTimeout(seconds: Int, message: String) {
        watchdog?.cancel()
        let token = generation
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, token == generation else { return }
            fail(message)
        }
    }

    private func fail(_ detail: String) {
        stopWork()
        setPhase(.failed(detail))
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        onChange?()
    }
}

struct TranslationStatusView: View {
    @ObservedObject var model: OverlayTranslation

    var body: some View {
        HStack(spacing: 5) {
            if model.phase.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 13, height: 13)
            }
            Text(model.phase.caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.phase.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let job = model.job {
                Color.clear.translationTask(job.configuration) { session in
                    await model.translate(job, using: session)
                }
                .id(job.id)
            }
        }
    }
}
