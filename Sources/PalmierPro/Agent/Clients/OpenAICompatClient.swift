import Foundation

struct OpenAICompatClient: AgentClient {
    let apiKey: String
    let model: LLMModel

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
        guard let endpoint = model.provider.openAIEndpoint else {
            throw AnthropicClientError.streamError("No endpoint for provider \(model.provider.rawValue)")
        }

        let body = buildRequestBody(system: system, tools: tools, messages: messages)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var bodyStr = ""
            for try await line in bytes.lines { bodyStr += line + "\n" }
            throw AnthropicClientError.httpError(status: http.statusCode, body: bodyStr)
        }

        try await parseSSE(bytes: bytes, continuation: continuation)
    }

    // MARK: - Request

    private func buildRequestBody(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> [String: Any] {
        var oaiMessages: [[String: Any]] = [["role": "system", "content": system]]
        for msg in messages {
            oaiMessages.append(contentsOf: convertMessage(msg))
        }

        let oaiTools: [[String: Any]] = tools.map { tool in
            ["type": "function", "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.inputSchema,
            ]]
        }

        var body: [String: Any] = [
            "model": model.id,
            "messages": oaiMessages,
            "stream": true,
        ]
        if !oaiTools.isEmpty { body["tools"] = oaiTools }
        return body
    }

    private func convertMessage(_ msg: AnthropicMessage) -> [[String: Any]] {
        switch msg.role {
        case .user: convertUserMessage(msg.content)
        case .assistant: [convertAssistantMessage(msg.content)]
        }
    }

    private func convertUserMessage(_ content: [[String: Any]]) -> [[String: Any]] {
        var toolMessages: [[String: Any]] = []
        var userBlocks: [[String: Any]] = []

        for block in content {
            switch block["type"] as? String ?? "" {
            case "tool_result":
                let toolUseId = block["tool_use_id"] as? String ?? ""
                let contentBlocks = block["content"] as? [[String: Any]] ?? []
                let isError = block["is_error"] as? Bool ?? false
                let text = contentBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let body = isError ? "[Error] \(text)" : text
                toolMessages.append(["role": "tool", "tool_call_id": toolUseId, "content": body])

            case "image":
                if let source = block["source"] as? [String: Any],
                   let mediaType = source["media_type"] as? String,
                   let data = source["data"] as? String {
                    userBlocks.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mediaType);base64,\(data)"],
                    ])
                }

            case "text":
                var stripped = block
                stripped.removeValue(forKey: "cache_control")
                userBlocks.append(stripped)

            default:
                break
            }
        }

        var result = toolMessages
        if !userBlocks.isEmpty {
            result.append(["role": "user", "content": userBlocks])
        }
        return result
    }

    private func convertAssistantMessage(_ content: [[String: Any]]) -> [String: Any] {
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []

        for block in content {
            switch block["type"] as? String ?? "" {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { textParts.append(text) }
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
                let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": argsJSON],
                ])
            default:
                break
            }
        }

        var msg: [String: Any] = ["role": "assistant"]
        let combined = textParts.joined()
        if !combined.isEmpty { msg["content"] = combined }
        if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
        return msg
    }

    // MARK: - SSE parser

    private func parseSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var pendingCalls: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let fr = choice["finish_reason"] as? String, !fr.isEmpty {
                finishReason = fr
            }

            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }

            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    guard let idx = call["index"] as? Int else { continue }
                    let id = call["id"] as? String ?? ""
                    let fn = call["function"] as? [String: Any] ?? [:]
                    let name = fn["name"] as? String ?? ""
                    let args = fn["arguments"] as? String ?? ""

                    var acc = pendingCalls[idx] ?? (id: "", name: "", args: "")
                    if !id.isEmpty { acc.id = id }
                    if !name.isEmpty { acc.name = name }
                    acc.args += args
                    pendingCalls[idx] = acc
                }
            }
        }

        // Flush completed tool calls in order
        for key in pendingCalls.keys.sorted() {
            guard let call = pendingCalls[key] else { continue }
            let json = call.args.isEmpty ? "{}" : call.args
            continuation.yield(.toolUseComplete(id: call.id, name: call.name, inputJSON: json))
        }

        let stopReason: AnthropicStopReason = switch finishReason {
            case "tool_calls": .toolUse
            case "length": .maxTokens
            default: .endTurn
        }
        continuation.yield(.messageStop(stopReason: stopReason))
    }
}
