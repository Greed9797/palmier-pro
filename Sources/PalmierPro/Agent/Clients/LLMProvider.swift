import Foundation

// MARK: - Provider

enum LLMProvider: String, CaseIterable, Codable, Identifiable, Hashable {
    case anthropic
    case openAI = "openai"
    case gemini
    case minimax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .minimax: "MiniMax"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-..."
        case .openAI: "sk-..."
        case .gemini: "AIza..."
        case .minimax: "eyJh..."
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")!
        case .minimax: URL(string: "https://platform.minimax.io/user-center/basic-information/interface-key")!
        }
    }

    // nil = use AnthropicClient; non-nil = use OpenAICompatClient
    var openAIEndpoint: URL? {
        switch self {
        case .anthropic: nil
        case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .minimax: URL(string: "https://api.minimax.io/v1/chat/completions")
        }
    }

    var keychainAccount: String { "\(rawValue)-api-key" }

    var models: [LLMModel] {
        switch self {
        case .anthropic:
            return AnthropicModel.allCases.map { LLMModel(id: $0.rawValue, displayName: $0.displayName, provider: .anthropic) }
        case .openAI:
            return [
                LLMModel(id: "gpt-4o", displayName: "GPT-4o", provider: .openAI),
                LLMModel(id: "gpt-4o-mini", displayName: "GPT-4o mini", provider: .openAI),
                LLMModel(id: "o3", displayName: "o3", provider: .openAI),
                LLMModel(id: "o4-mini", displayName: "o4-mini", provider: .openAI),
            ]
        case .gemini:
            return [
                LLMModel(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .gemini),
                LLMModel(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .gemini),
                LLMModel(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash", provider: .gemini),
            ]
        case .minimax:
            return [
                LLMModel(id: "MiniMax-Text-01", displayName: "MiniMax Text-01", provider: .minimax),
                LLMModel(id: "abab6.5s-chat", displayName: "abab6.5s", provider: .minimax),
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
