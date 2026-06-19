import Foundation

/// Runs a locally-installed coding CLI (`claude` or `codex`) as the agent backend.
/// No API key: it uses the user's existing CLI login/subscription. The CLI edits the
/// timeline through the already-running palmier-pro MCP server. Output is streamed line
/// by line so the chat shows progress live, and the whole run is bounded by a timeout.
struct CLIClient: AgentClient {
    enum Kind: String, Sendable {
        case claude, codex
        var binary: String { rawValue }
    }

    let kind: Kind
    let model: LLMModel
    var codexEffort: String = "medium"
    var codexFastMode: Bool = true

    private static let timeoutSeconds: Double = 300

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
        process.arguments = ["-lc", command(codexOutFile: codexOut?.path)]
        // Neutral cwd: no stray AGENTS.md / CLAUDE.md / project settings get pulled in.
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let stdinPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        nonisolated(unsafe) let outHandle = outPipe.fileHandleForReading
        nonisolated(unsafe) let errHandle = errPipe.fileHandleForReading
        nonisolated(unsafe) let proc = process

        try Task.checkCancellation()
        try process.run()

        let stdinHandle = stdinPipe.fileHandleForWriting
        stdinHandle.write(Data(prompt.utf8))
        try? stdinHandle.close()

        // Instant feedback: the CLI reasons silently for a few seconds before its
        // first event, so show life immediately instead of a dead spinner.
        continuation.yield(.textDelta("→ \(kind.binary) working…\n"))

        // Drain stderr concurrently so a flood can't fill the pipe and block the process.
        let errTask = Task.detached { String(decoding: errHandle.readDataToEndOfFile(), as: UTF8.self) }

        // Overall deadline — terminate the subprocess (closes stdout → ends the read loop)
        // so a wedged CLI / MCP call can't spin forever. No shared flag: timeout is inferred
        // post-hoc from the signal-kill + elapsed time (avoids a data race on a Bool).
        let start = ContinuousClock.now
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            if proc.isRunning { proc.terminate() }
        }
        defer { timeout.cancel() }

        // Stream stdout line by line as the CLI produces it.
        var didYield = false
        var fallback: String?
        do {
            for try await line in outHandle.bytes.lines {
                let parsed = Self.parse(line: line, kind: kind)
                if let final = parsed.final { fallback = final }
                for frag in parsed.frags where !frag.isEmpty {
                    continuation.yield(.textDelta(frag))
                    didYield = true
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // read-stream error — fall through to status handling
        }

        timeout.cancel()
        process.waitUntilExit()  // stdout EOF already means the process is exiting → returns immediately
        let stderr = await errTask.value
        let timedOut = process.terminationReason == .uncaughtSignal
            && ContinuousClock.now - start >= .seconds(Self.timeoutSeconds - 1)

        if timedOut {
            throw AnthropicClientError.streamError(
                "\(kind.binary) timed out after \(Int(Self.timeoutSeconds))s and was stopped.")
        }
        if process.terminationStatus == 127 || stderr.contains("command not found") {
            throw AnthropicClientError.streamError(
                "\(kind.binary) CLI not found on PATH. Install it and sign in (`\(kind.binary)`).")
        }
        if process.terminationStatus != 0 && !didYield {
            let detail = stderr.isEmpty ? (fallback ?? "") : stderr
            throw AnthropicClientError.streamError(
                "\(kind.binary) exited \(process.terminationStatus): \(String(detail.suffix(400)))")
        }

        if !didYield {
            // Nothing streamed — use the codex final-message file or the captured result.
            var finalText = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if finalText.isEmpty, let codexOut, let f = try? String(contentsOf: codexOut, encoding: .utf8) {
                finalText = f.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            continuation.yield(.textDelta(finalText.isEmpty
                ? "(\(kind.binary) finished — the timeline may have been edited via MCP.)"
                : finalText))
        }
        if let codexOut { try? FileManager.default.removeItem(at: codexOut) }
        continuation.yield(.messageStop(stopReason: .endTurn))
    }

    // MARK: - Per-line parsing

    private struct Parsed { var frags: [String]; var final: String? }

    /// Defensive: tolerate either CLI's JSON-lines schema; never throw on a bad line.
    private static func parse(line: String, kind: Kind) -> Parsed {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return Parsed(frags: [], final: nil) }

        switch kind {
        case .claude:
            if type == "assistant", let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                var frags: [String] = []
                for block in content {
                    switch block["type"] as? String {
                    case "text": if let t = block["text"] as? String, !t.isEmpty { frags.append(t) }
                    case "tool_use": if let n = block["name"] as? String { frags.append("\n→ \(n)…\n") }
                    default: break
                    }
                }
                return Parsed(frags: frags, final: nil)
            }
            if type == "result" { return Parsed(frags: [], final: obj["result"] as? String) }
            return Parsed(frags: [], final: nil)

        case .codex:
            // codex exec --json emits item events; surface agent messages, note tool/command runs.
            if let item = obj["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                if itemType.contains("agent_message") || itemType.contains("assistant") {
                    if let t = item["text"] as? String, !t.isEmpty { return Parsed(frags: [t], final: nil) }
                }
                if itemType.contains("command") || itemType.contains("mcp") || itemType.contains("tool") {
                    let label = (item["command"] as? String) ?? (item["name"] as? String) ?? itemType
                    return Parsed(frags: ["\n→ \(label)…\n"], final: nil)
                }
            }
            if type.contains("message"), let t = obj["text"] as? String, !t.isEmpty {
                return Parsed(frags: [t], final: nil)
            }
            return Parsed(frags: [], final: nil)
        }
    }

    // MARK: - Command + prompt

    // Only the palmier-pro MCP server — NOT the user's full CLI MCP fleet. Loading every
    // configured server (the user may have 20+, some needing auth) makes `-p`/`exec` hang
    // for minutes at startup. strict/override pins it to just the editor's server.
    private static let palmierMCP = "http://127.0.0.1:19789/mcp"

    private func command(codexOutFile: String?) -> String {
        let modelArg = Self.isDefaultModel(model.id) ? "" : Self.sanitizedModelFlag(kind: kind, id: model.id)
        switch kind {
        case .claude:
            // stream-json --verbose: live message events. strict-mcp-config: only palmier-pro.
            // skip-permissions: -p has no TTY to approve tool calls → would hang.
            // setting-sources project,local: skip the user's global hooks/skills (which flood the
            // stream and add seconds of startup) WITHOUT dropping auth — unlike --bare, which logs out.
            let mcp = "--strict-mcp-config --mcp-config '{\"mcpServers\":{\"palmier-pro\":{\"type\":\"http\",\"url\":\"\(Self.palmierMCP)\"}}}'"
            return "claude -p --output-format stream-json --verbose --dangerously-skip-permissions --setting-sources project,local \(mcp)\(modelArg)"
        case .codex:
            // ignore-user-config: skip the user's ~/.codex config (heavy plugins/skills, slow startup);
            // auth still uses CODEX_HOME and our -c overrides below still apply.
            // -c mcp_servers={...}: override the codex config table to just palmier-pro.
            let mcp = "-c 'mcp_servers={palmier-pro={url=\"\(Self.palmierMCP)\"}}'"
            let effort = Self.isSafeToken(codexEffort) ? " -c model_reasoning_effort=\(codexEffort)" : ""
            let fast = codexFastMode ? " -c service_tier=\"fast\"" : ""
            let out = codexOutFile.map { " -o '\($0)'" } ?? ""
            return "codex exec --json --ignore-user-config --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \(mcp)\(effort)\(fast)\(out)\(modelArg)"
        }
    }

    private static func isDefaultModel(_ id: String) -> Bool { id == "default" || id.isEmpty }

    private static func isSafeToken(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Only allow a conservative id charset, then format the per-CLI flag.
    private static func sanitizedModelFlag(kind: Kind, id: String) -> String {
        guard isSafeToken(id) else { return "" }
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
