import Foundation

// MARK: - Provider

enum LLMProvider: String, CaseIterable, Codable, Identifiable, Hashable {
    case anthropic
    case openAI = "openai"
    case gemini
    case minimax
    case nvidia
    case claudeCLI = "claude-cli"
    case codexCLI = "codex-cli"

    var id: String { rawValue }

    /// CLI providers run a locally-installed agent binary instead of an HTTP API.
    var usesCLI: Bool { self == .claudeCLI || self == .codexCLI }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .minimax: "MiniMax"
        case .nvidia: "NVIDIA NIM"
        case .claudeCLI: "Claude Code (CLI)"
        case .codexCLI: "Codex (CLI)"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-..."
        case .openAI: "sk-..."
        case .gemini: "AIza..."
        case .minimax: "eyJh..."
        case .nvidia: "nvapi-..."
        case .claudeCLI, .codexCLI: ""
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")!
        case .minimax: URL(string: "https://platform.minimax.io/user-center/basic-information/interface-key")!
        case .nvidia: URL(string: "https://build.nvidia.com/settings/api-keys")!
        case .claudeCLI: URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!
        case .codexCLI: URL(string: "https://github.com/openai/codex")!
        }
    }

    // nil = use AnthropicClient (or a CLI when usesCLI); non-nil = use OpenAICompatClient
    var openAIEndpoint: URL? {
        switch self {
        case .anthropic, .claudeCLI, .codexCLI: nil
        case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .minimax: URL(string: "https://api.minimax.io/v1/chat/completions")
        case .nvidia: URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")
        }
    }

    var keychainAccount: String { "\(rawValue)-api-key" }

    var models: [LLMModel] {
        switch self {
        case .anthropic:
            return AnthropicModel.allCases.map { LLMModel(id: $0.rawValue, displayName: $0.displayName, provider: .anthropic) }
        case .openAI:
            return [
                LLMModel(id: "gpt-5.5", displayName: "GPT-5.5", provider: .openAI),
                LLMModel(id: "gpt-5.5-pro", displayName: "GPT-5.5 Pro", provider: .openAI),
                LLMModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini", provider: .openAI),
                LLMModel(id: "gpt-5.4-nano", displayName: "GPT-5.4 nano", provider: .openAI),
            ]
        case .gemini:
            return [
                LLMModel(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", provider: .gemini),
                LLMModel(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro", provider: .gemini),
                LLMModel(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite", provider: .gemini),
            ]
        case .minimax:
            return [
                LLMModel(id: "MiniMax-M3", displayName: "MiniMax M3 (multimodal)", provider: .minimax),
                LLMModel(id: "MiniMax-M2.7", displayName: "MiniMax M2.7", provider: .minimax),
                LLMModel(id: "MiniMax-M2.5", displayName: "MiniMax M2.5", provider: .minimax),
            ]
        case .nvidia:
            // NVIDIA NIM OpenAI-compatible endpoint — hosts MiniMax + others. Works with an
            // nvapi- key (build.nvidia.com), unlike api.minimax.io which needs a MiniMax JWT.
            return [
                LLMModel(id: "minimaxai/minimax-m3", displayName: "MiniMax M3", provider: .nvidia),
                LLMModel(id: "minimaxai/minimax-m2.7", displayName: "MiniMax M2.7", provider: .nvidia),
                LLMModel(id: "deepseek-ai/deepseek-r1", displayName: "DeepSeek R1", provider: .nvidia),
                LLMModel(id: "meta/llama-3.3-70b-instruct", displayName: "Llama 3.3 70B", provider: .nvidia),
            ]
        case .claudeCLI:
            return [
                LLMModel(id: "sonnet", displayName: "Claude Sonnet", provider: .claudeCLI),
                LLMModel(id: "opus", displayName: "Claude Opus", provider: .claudeCLI),
                LLMModel(id: "haiku", displayName: "Claude Haiku", provider: .claudeCLI),
            ]
        case .codexCLI:
            return [
                LLMModel(id: "gpt-5.5", displayName: "GPT-5.5", provider: .codexCLI),
                LLMModel(id: "gpt-5.5-codex", displayName: "GPT-5.5 Codex", provider: .codexCLI),
                LLMModel(id: "gpt-5.4-codex", displayName: "GPT-5.4 Codex", provider: .codexCLI),
            ]
        }
    }
}

// MARK: - Model

struct LLMModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let provider: LLMProvider
}
