import Foundation

extension Notification.Name {
    static let deepgramAPIKeyChanged = Notification.Name("deepgramAPIKeyChanged")
}

/// BYOK key for Deepgram speech-to-text. Not an LLM provider, so it bypasses
/// ProviderKeychain and stores directly under a fixed Keychain account.
enum DeepgramKeychain {
    private static let account = "deepgram-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .deepgramAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .deepgramAPIKeyChanged, object: nil)
    }

    static var hasKey: Bool {
        guard let key = load() else { return false }
        return !key.isEmpty
    }
}
