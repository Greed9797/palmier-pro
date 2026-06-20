import SwiftUI

/// CapCut-style animated captions: short word groups that pop/fade in synced to speech.
/// Reuses the transcription + caption pipeline (`generateCaptions`, word mode) and adds an
/// entrance animation per caption clip.
struct CustomCaptionsTab: View {
    @Environment(EditorViewModel.self) var editor

    @State private var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
    @State private var center = AppTheme.Caption.defaultCenter
    @State private var textCase: EditorViewModel.CaptionCase = .auto
    @State private var animStyle: CaptionAnimation.Style = .popIn
    @State private var wordsPerCaption: Int = 2
    @State private var entryFrames: Int = 4
    @State private var locale: Locale?
    @State private var supportedLocales: [Locale] = []
    @State private var isGenerating = false
    @State private var note: String?

    private var selectedTargets: [String] {
        let sel = editor.selectedClipIds
        guard !sel.isEmpty else { return [] }
        return editor.captionTargets(ids: Array(sel)).map(\.id)
    }
    private var isAutoSource: Bool { selectedTargets.isEmpty }
    private var effectiveCount: Int {
        isAutoSource ? editor.captionTargets(ids: []).count : selectedTargets.count
    }
    private var sourceSummary: String {
        if !selectedTargets.isEmpty { return "Selected · \(selectedTargets.count)" }
        return editor.captionTargets(ids: []).isEmpty ? "No audio" : "Auto"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                        animationSection
                        styleSection
                        placementSection
                        sourceSection
                    }
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.vertical, AppTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: "Transcribing…", size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .task {
            guard supportedLocales.isEmpty else { return }
            supportedLocales = (await Transcription.supportedLocales())
                .sorted { languageName($0) < languageName($1) }
        }
    }

    private var animationSection: some View {
        InspectorSection("Animation") {
            InspectorRow(icon: "sparkles", label: "Entrance") {
                Menu {
                    ForEach(CaptionAnimation.Style.allCases, id: \.self) { s in
                        Button(s.label) { animStyle = s }
                    }
                } label: { menuValueLabel(animStyle.label) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            }
            InspectorRow(icon: "text.word.spacing", label: "Words / caption") {
                Menu {
                    ForEach(1...6, id: \.self) { n in Button("\(n)") { wordsPerCaption = n } }
                } label: { menuValueLabel(animStyle.prefersOneWord ? "1" : "\(wordsPerCaption)") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
                .disabled(animStyle.prefersOneWord)
            }
            InspectorRow(icon: "speedometer", label: "Speed") {
                ScrubbableNumberField(
                    value: Double(entryFrames), range: 1...20, format: "%.0f", valueSuffix: " f",
                    onChanged: { entryFrames = max(1, Int($0)) }
                ) { entryFrames = max(1, Int($0)) }
            }
        }
    }

    private var styleSection: some View {
        InspectorSection("Style") {
            InspectorRow(icon: "character", label: "Font") {
                FontPickerField(current: style.fontName, onPreview: { style.fontName = $0 }, onChange: { style.fontName = $0 }, onCancel: {})
            }
            InspectorRow(icon: "textformat.size", label: "Size") {
                ScrubbableNumberField(
                    value: style.fontSize, range: AppTheme.Caption.minFontSize...AppTheme.Caption.maxFontSize,
                    format: "%.0f", valueSuffix: " pt", onChanged: { style.fontSize = $0 }
                ) { style.fontSize = $0 }
            }
            InspectorRow(icon: "paintpalette", label: "Color") {
                ColorField(displayColor: style.color.swiftUIColor, onUserChange: { style.color = TextStyle.RGBA($0) })
            }
            InspectorRow(icon: "textformat", label: "Case") {
                Menu {
                    ForEach(EditorViewModel.CaptionCase.allCases, id: \.self) { c in
                        Button(c.label) { textCase = c }
                    }
                } label: { menuValueLabel(textCase.label) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            }
        }
    }

    private var placementSection: some View {
        InspectorSection("Placement") {
            HStack(spacing: AppTheme.Spacing.mdLg) {
                Spacer(minLength: AppTheme.Spacing.xs)
                posField("X", value: center.x) { center.x = $0 }
                posField("Y", value: center.y) { center.y = $0 }
            }
        }
    }

    private var sourceSection: some View {
        InspectorSection("Source") {
            InspectorRow(icon: "waveform", label: "Source", labelHelp: "Uses selected clips when available, otherwise all captionable audio.") {
                Text(sourceSummary)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            InspectorRow(icon: "globe", label: "Language") {
                Menu {
                    Button("Auto") { locale = nil }
                    if !supportedLocales.isEmpty {
                        Divider()
                        ForEach(supportedLocales, id: \.identifier) { loc in
                            Button(languageName(loc)) { locale = loc }
                        }
                    }
                } label: { menuValueLabel(locale.map(languageName) ?? "Auto") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            }
        }
    }

    private var generateBar: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if let note {
                Text(note)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: generate) {
                Text("Generate Captions")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Background.baseColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
                    .opacity(effectiveCount == 0 ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
            }
            .buttonStyle(.plain).focusable(false)
            .disabled(effectiveCount == 0 || isGenerating)
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private func generate() {
        note = nil
        var words = wordsPerCaption
        if animStyle.prefersOneWord { words = 1 }
        let animation = CaptionAnimation(style: animStyle, entryFrames: entryFrames)
        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: selectedTargets, autoDetect: isAutoSource, style: style, center: center,
            textCase: textCase, censorProfanity: false, locale: locale,
            wordsPerCaption: max(1, words), animation: animation
        )
        Task {
            isGenerating = true
            defer { isGenerating = false }
            do {
                let ids = try await editor.generateCaptions(for: request)
                if ids.isEmpty { note = "No speech detected." }
            } catch {
                note = error.localizedDescription
            }
        }
    }

    private func languageName(_ loc: Locale) -> String {
        Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier(.bcp47)
    }

    private func menuValueLabel(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .lineLimit(1)
    }

    private func posField(_ label: String, value: CGFloat, onChange: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ScrubbableNumberField(
                value: Double(value),
                range: AppTheme.Caption.minPosition...AppTheme.Caption.maxPosition,
                displayMultiplier: 100, format: "%.0f", valueSuffix: "%",
                onChanged: { onChange(CGFloat($0)) }
            ) { onChange(CGFloat($0)) }
        }
    }
}
