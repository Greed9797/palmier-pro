import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var agentService = AgentService.shared
    @State private var selectedTab: LLMProvider = AgentService.shared.selectedProvider
    @State private var draftKeys: [LLMProvider: String] = [:]
    @State private var maskedKeys: [LLMProvider: String] = [:]
    @State private var hasKeys: [LLMProvider: Bool] = [:]
    @FocusState private var focusedProvider: LLMProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            providerSection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
        }
        .onAppear(perform: refreshAll)
    }

    // MARK: - Provider section

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            providerPicker
            keySection(for: selectedTab)
        }
    }

    private var providerPicker: some View {
        HStack(spacing: 0) {
            ForEach(LLMProvider.allCases) { provider in
                providerTab(provider)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func providerTab(_ provider: LLMProvider) -> some View {
        let isSelected = selectedTab == provider
        let isActive = agentService.selectedProvider == provider
        return Button(action: { selectedTab = provider }) {
            HStack(spacing: AppTheme.Spacing.xs) {
                if hasKeys[provider] == true {
                    Circle()
                        .fill(isActive ? AppTheme.Accent.primary : Color.green.opacity(0.7))
                        .frame(width: 5, height: 5)
                }
                Text(provider.displayName)
                    .font(.system(size: AppTheme.FontSize.sm, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(isSelected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func keySection(for provider: LLMProvider) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            keyHeader(for: provider)
            keyField(for: provider)
            if hasKeys[provider] == true {
                useProviderButton(provider)
            }
        }
    }

    private func keyHeader(for provider: LLMProvider) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text("API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Spacer()

            Button(action: { NSWorkspace.shared.open(provider.consoleURL, configuration: .init(), completionHandler: nil) }) {
                HStack(spacing: 2) {
                    Text("Get \(provider.displayName) key")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private func keyField(for provider: LLMProvider) -> some View {
        let draft = Binding<String>(
            get: { draftKeys[provider] ?? "" },
            set: { draftKeys[provider] = $0 }
        )
        let isFocused = focusedProvider == provider
        let hasKey = hasKeys[provider] == true
        let masked = maskedKeys[provider] ?? ""

        return HStack(spacing: AppTheme.Spacing.sm) {
            SecureField(hasKey ? masked : provider.apiKeyPlaceholder, text: draft)
                .textFieldStyle(.plain)
                .focused($focusedProvider, equals: provider)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit { save(provider: provider) }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.black.opacity(AppTheme.Opacity.muted))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                )
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)

            trailingControl(for: provider, draft: draft.wrappedValue, hasKey: hasKey)
        }
    }

    @ViewBuilder
    private func trailingControl(for provider: LLMProvider, draft: String, hasKey: Bool) -> some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save") { save(provider: provider) }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: { remove(provider: provider) }) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove \(provider.displayName) API key")
        }
    }

    private func useProviderButton(_ provider: LLMProvider) -> some View {
        let isActive = agentService.selectedProvider == provider
        return HStack {
            if isActive {
                Label("Active for agent chat", systemImage: "checkmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
            } else {
                Button("Use \(provider.displayName) for agent chat") {
                    agentService.selectedProvider = provider
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .font(.system(size: AppTheme.FontSize.sm))
            }
        }
    }

    // MARK: - Actions

    private func refreshAll() {
        for provider in LLMProvider.allCases {
            refresh(provider: provider)
        }
    }

    private func refresh(provider: LLMProvider) {
        let key = ProviderKeychain.load(for: provider) ?? ""
        hasKeys[provider] = !key.isEmpty
        maskedKeys[provider] = mask(key)
    }

    private func save(provider: LLMProvider) {
        let key = (draftKeys[provider] ?? "").trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        ProviderKeychain.save(key, for: provider)
        draftKeys[provider] = ""
        focusedProvider = nil
        refresh(provider: provider)
        // Auto-activate newly configured provider
        if agentService.selectedProvider != provider {
            agentService.selectedProvider = provider
        }
    }

    private func remove(provider: LLMProvider) {
        ProviderKeychain.delete(for: provider)
        draftKeys[provider] = ""
        refresh(provider: provider)
        // Switch back to Anthropic if active provider was removed
        if agentService.selectedProvider == provider {
            agentService.selectedProvider = .anthropic
        }
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }

    // MARK: - MCP section

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpHeader
            mcpStatusRow
        }
    }

    private var mcpHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("MCP Server")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: 2) {
                        Text("Setup instructions")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? Color.green : AppTheme.Text.mutedColor)
                    .frame(width: 8, height: 8)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("Running on ")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text("127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}
