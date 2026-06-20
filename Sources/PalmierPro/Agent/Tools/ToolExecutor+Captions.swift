import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = [
        "clipIds", "fontName", "fontSize", "color", "centerX", "centerY", "textCase", "censorProfanity", "language",
    ]

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let clipIds = (args["clipIds"] as? [Any])?.compactMap { $0 as? String } ?? []

        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        if let f = args.string("fontName") { style.fontName = f }
        if let s = args.double("fontSize") { style.fontSize = s }
        if let c = try parseColorHex(args.string("color"), path: "add_captions") { style.color = c }

        var locale: Locale?
        if let lang = args.string("language") {
            let candidate = Locale(identifier: lang)
            guard let match = Transcription.matchLocale(candidates: [candidate], supported: await Transcription.supportedLocales()) else {
                throw ToolError("add_captions: on-device transcription does not support language '\(lang)'.")
            }
            locale = match
        }

        var center = AppTheme.Caption.defaultCenter
        if let x = args.double("centerX") { center.x = CGFloat(x) }
        if let y = args.double("centerY") { center.y = CGFloat(y) }

        var textCase: EditorViewModel.CaptionCase = .auto
        if let raw = args.string("textCase") {
            guard let parsed = EditorViewModel.CaptionCase(rawValue: raw) else {
                throw ToolError("add_captions: textCase must be auto, upper, or lower (got \(raw))")
            }
            textCase = parsed
        }

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: clipIds,
            autoDetect: clipIds.isEmpty,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: locale
        )

        let ids = try await editor.generateCaptions(for: request)
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return .ok("Added \(ids.count) caption\(ids.count == 1 ? "" : "s").")
    }

    private static let addWordCaptionsAllowedKeys: Set<String> = [
        "clipIds", "fontName", "fontSize", "color", "centerX", "centerY",
        "textCase", "language", "wordsPerCaption", "animation", "entryFrames",
    ]

    /// CapCut-style animated captions: short word groups that pop/fade in synced to speech.
    func addWordCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addWordCaptionsAllowedKeys, path: "add_word_captions")

        let clipIds = (args["clipIds"] as? [Any])?.compactMap { $0 as? String } ?? []

        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        if let f = args.string("fontName") { style.fontName = f }
        if let s = args.double("fontSize") { style.fontSize = s }
        if let c = try parseColorHex(args.string("color"), path: "add_word_captions") { style.color = c }

        var locale: Locale?
        if let lang = args.string("language") {
            let candidate = Locale(identifier: lang)
            guard let match = Transcription.matchLocale(candidates: [candidate], supported: await Transcription.supportedLocales()) else {
                throw ToolError("add_word_captions: on-device transcription does not support language '\(lang)'.")
            }
            locale = match
        }

        var center = AppTheme.Caption.defaultCenter
        if let x = args.double("centerX") { center.x = CGFloat(x) }
        if let y = args.double("centerY") { center.y = CGFloat(y) }

        var textCase: EditorViewModel.CaptionCase = .auto
        if let raw = args.string("textCase") {
            guard let parsed = EditorViewModel.CaptionCase(rawValue: raw) else {
                throw ToolError("add_word_captions: textCase must be auto, upper, or lower (got \(raw))")
            }
            textCase = parsed
        }

        var animation = CaptionAnimation()
        if let raw = args.string("animation") {
            guard let parsed = CaptionAnimation.Style(rawValue: raw) else {
                throw ToolError("add_word_captions: animation must be popIn, bounce, fade, or typewriter (got \(raw))")
            }
            animation.style = parsed
        }
        if let n = args.double("entryFrames") { animation.entryFrames = max(1, Int(n)) }

        var wordsPerCaption = Int(args.double("wordsPerCaption") ?? 2)
        if animation.style.prefersOneWord { wordsPerCaption = 1 }
        wordsPerCaption = max(1, min(6, wordsPerCaption))

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: clipIds,
            autoDetect: clipIds.isEmpty,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: false,
            locale: locale,
            wordsPerCaption: wordsPerCaption,
            animation: animation
        )

        let ids = try await editor.generateCaptions(for: request)
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return .ok("Added \(ids.count) animated caption\(ids.count == 1 ? "" : "s") (\(animation.style.rawValue), \(wordsPerCaption) word/caption).")
    }
}
