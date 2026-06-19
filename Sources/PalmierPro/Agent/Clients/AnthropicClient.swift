import Foundation

extension Notification.Name {
    static let anthropicAPIKeyChanged = Notification.Name("anthropicAPIKeyChanged")
}

// Delegates to ProviderKeychain; kept for backward compatibility.
enum AnthropicKeychain {
    static func save(_ key: String) {
        ProviderKeychain.save(key, for: .anthropic)
        NotificationCenter.default.post(name: .anthropicAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        ProviderKeychain.load(for: .anthropic)
    }

    static func delete() {
        ProviderKeychain.delete(for: .anthropic)
        NotificationCenter.default.post(name: .anthropicAPIKeyChanged, object: nil)
    }
}

struct AnthropicClient: AgentClient {
    let apiKey: String
    let model: AnthropicModel
    var maxTokens: Int = 8192

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AnthropicClientError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(
                model: model, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
            options: [.sortedKeys]
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AnthropicClientError.httpError(status: http.statusCode, body: body)
        }

        try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
    }
}
