import Foundation

extension Notification.Name {
    static let providerAPIKeyChanged = Notification.Name("providerAPIKeyChanged")
}

enum ProviderKeychain {
    static func save(_ key: String, for provider: LLMProvider) {
        KeychainStore.save(key, account: provider.keychainAccount)
        NotificationCenter.default.post(name: .providerAPIKeyChanged, object: provider.rawValue)
    }

    static func load(for provider: LLMProvider) -> String? {
        #if DEBUG
        let envKey: String
        switch provider {
        case .anthropic: envKey = "ANTHROPIC_API_KEY"
        case .openAI: envKey = "OPENAI_API_KEY"
        case .gemini: envKey = "GEMINI_API_KEY"
        case .minimax: envKey = "MINIMAX_API_KEY"
        }
        if let env = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: provider.keychainAccount)
    }

    static func delete(for provider: LLMProvider) {
        KeychainStore.delete(account: provider.keychainAccount)
        NotificationCenter.default.post(name: .providerAPIKeyChanged, object: provider.rawValue)
    }

    static func hasKey(for provider: LLMProvider) -> Bool {
        guard let key = load(for: provider) else { return false }
        return !key.isEmpty
    }
}
