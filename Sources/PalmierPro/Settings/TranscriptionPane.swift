import AppKit
import SwiftUI

/// Settings → General section for the optional Deepgram BYOK transcription key.
/// When set, caption generation uses Deepgram instead of the on-device transcriber.
struct TranscriptionPane: View {
    @State private var hasKey = false
    @State private var masked = ""
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let consoleURL = URL(string: "https://console.deepgram.com/")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            keyField
            Text("Optional. With a key, captions are transcribed by Deepgram (higher accuracy, BCP-47 languages). Without it, captions use the on-device transcriber.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text("Deepgram API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
            Button(action: { NSWorkspace.shared.open(consoleURL, configuration: .init(), completionHandler: nil) }) {
                HStack(spacing: 2) {
                    Text("Get Deepgram key")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private var keyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            SecureField(hasKey ? masked : "Token …", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit(save)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.black.opacity(AppTheme.Opacity.muted))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            focused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                )
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: focused)

            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove Deepgram API key")
        }
    }

    private func refresh() {
        let key = DeepgramKeychain.load() ?? ""
        hasKey = !key.isEmpty
        masked = key.count > 4
            ? String(repeating: "\u{2022}", count: 32) + key.suffix(4)
            : String(repeating: "\u{2022}", count: min(key.count, 24))
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        DeepgramKeychain.save(key)
        draft = ""
        focused = false
        refresh()
    }

    private func remove() {
        DeepgramKeychain.delete()
        draft = ""
        refresh()
    }
}
