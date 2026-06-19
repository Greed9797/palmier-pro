import Foundation

/// Runs a locally-installed coding CLI (`claude` or `codex`) as the agent backend.
/// No API key: it uses the user's existing CLI login/subscription. The CLI edits the
/// timeline through the already-running palmier-pro MCP server, then we surface its
/// final message in the chat panel. One-shot (no token streaming) for robustness.
struct CLIClient: AgentClient {
    enum Kind: String, Sendable {
        case claude, codex
        var binary: String { rawValue }
    }

    let kind: Kind
    let model: LLMModel

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            nonisolated(unsafe) let process = Process()
            let task = Task {
                do {
                    try await run(process: process, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func run(
        process: Process,
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        let prompt = Self.buildPrompt(messages: messages)
        guard !prompt.isEmpty else { throw AnthropicClientError.streamError("Nothing to send.") }

        let codexOut: URL? = kind == .codex
            ? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("palmier-codex-\(UUID().uuidString).txt")
            : nil

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", Self.command(kind: kind, model: model, codexOutFile: codexOut?.path)]

        let stdinPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        nonisolated(unsafe) let outHandle = outPipe.fileHandleForReading
        nonisolated(unsafe) let errHandle = errPipe.fileHandleForReading

        try Task.checkCancellation()
        try process.run()

        let stdinHandle = stdinPipe.fileHandleForWriting
        stdinHandle.write(Data(prompt.utf8))
        try? stdinHandle.close()

        let outData = await Task.detached { outHandle.readDataToEndOfFile() }.value
        let errData = await Task.detached { errHandle.readDataToEndOfFile() }.value
        await Task.detached { process.waitUntilExit() }.value
        try Task.checkCancellation()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)

        if process.terminationStatus == 127 || stderr.contains("command not found") {
            throw AnthropicClientError.streamError(
                "\(kind.binary) CLI not found on PATH. Install it and sign in (`\(kind.binary)`).")
        }
        if process.terminationStatus != 0 {
            let detail = stderr.isEmpty ? stdout : stderr
            throw AnthropicClientError.streamError(
                "\(kind.binary) exited \(process.terminationStatus): \(String(detail.suffix(400)))")
        }

        var finalText = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let codexOut {
            if let fileText = try? String(contentsOf: codexOut, encoding: .utf8) {
                finalText = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try? FileManager.default.removeItem(at: codexOut)
        }

        if finalText.isEmpty {
            continuation.yield(.textDelta(
                "(\(kind.binary) finished. The timeline may have been edited via MCP — no text was returned.)"))
        } else {
            continuation.yield(.textDelta(finalText))
        }
        continuation.yield(.messageStop(stopReason: .endTurn))
    }

    // MARK: - Command + prompt

    // Only the palmier-pro MCP server — NOT the user's full CLI MCP fleet. Loading every
    // configured server (the user may have 20+, some needing auth) makes `-p`/`exec` hang
    // for minutes at startup. strict/override pins it to just the editor's server.
    private static let palmierMCP = "http://127.0.0.1:19789/mcp"

    private static func command(kind: Kind, model: LLMModel, codexOutFile: String?) -> String {
        let modelArg = isDefaultModel(model.id) ? "" : sanitizedModelFlag(kind: kind, id: model.id)
        switch kind {
        case .claude:
            // --strict-mcp-config: ignore ~/.claude.json servers, load ONLY the one below.
            // --dangerously-skip-permissions: -p has no TTY to approve tool calls → would hang.
            let mcp = "--strict-mcp-config --mcp-config '{\"mcpServers\":{\"palmier-pro\":{\"type\":\"http\",\"url\":\"\(palmierMCP)\"}}}'"
            return "claude -p --dangerously-skip-permissions \(mcp)\(modelArg)"
        case .codex:
            // -c mcp_servers={...}: override the codex config table to just palmier-pro.
            let mcp = "-c 'mcp_servers={palmier-pro={url=\"\(palmierMCP)\"}}'"
            let out = codexOutFile.map { " -o '\($0)'" } ?? ""
            return "codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \(mcp)\(out)\(modelArg)"
        }
    }

    private static func isDefaultModel(_ id: String) -> Bool { id == "default" || id.isEmpty }

    /// Only allow a conservative id charset, then format the per-CLI flag.
    private static func sanitizedModelFlag(kind: Kind, id: String) -> String {
        let safe = id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        guard safe else { return "" }
        return kind == .claude ? " --model \(id)" : " -m \(id)"
    }

    private static func buildPrompt(messages: [AnthropicMessage]) -> String {
        var transcript = ""
        for message in messages {
            let text = message.content
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }
            transcript += "\(message.role.rawValue.uppercased()): \(text)\n\n"
        }
        guard !transcript.isEmpty else { return "" }
        return """
        You are the AI agent embedded in the Palmier Pro macOS video editor. \
        Use the palmier-pro MCP tools to read and edit the user's open timeline as needed, \
        then reply with a short summary of what you changed.

        \(transcript)
        """
    }
}
