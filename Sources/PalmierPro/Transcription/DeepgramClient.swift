import Foundation

enum DeepgramError: LocalizedError {
    case missingAPIKey
    case http(status: Int, errCode: String?, errMsg: String?)
    case emptyTranscript
    case decodeFailed(String)
    case audioExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No Deepgram API key set (Settings → General → Transcription)."
        case .http(let status, let code, let msg):
            "Deepgram error \(status)\(code.map { " (\($0))" } ?? ""): \(msg ?? "request failed")"
        case .emptyTranscript: "Deepgram returned no speech."
        case .decodeFailed(let m): "Couldn't parse Deepgram response: \(m)"
        case .audioExtractionFailed(let m): "Couldn't extract audio: \(m)"
        }
    }
}

/// Uploads local audio to Deepgram's prerecorded API and maps the response into
/// the app's canonical `TranscriptionResult`. Value type → Sendable; all work is
/// nonisolated async so it runs off the main actor (mirrors AnthropicClient).
struct DeepgramClient {
    let apiKey: String
    var model: String = "nova-3"

    func transcribe(fileURL: URL, contentType: String, language: String?) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DeepgramError.missingAPIKey }

        var comps = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
        ]
        if let language, !language.isEmpty {
            items.append(URLQueryItem(name: "language", value: language))
        } else {
            // No explicit locale → let Deepgram detect it (else nova-3 silently assumes English).
            items.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        comps.queryItems = items

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let err = try? JSONDecoder.deepgram.decode(DGErrorBody.self, from: data)
            throw DeepgramError.http(
                status: http.statusCode,
                errCode: err?.errCode ?? err?.error,
                errMsg: err?.errMsg ?? err?.message)
        }

        let decoded: DGResponse
        do { decoded = try JSONDecoder.deepgram.decode(DGResponse.self, from: data) }
        catch { throw DeepgramError.decodeFailed(error.localizedDescription) }

        guard let alt = decoded.results.channels.first?.alternatives.first else {
            throw DeepgramError.emptyTranscript
        }

        let words = alt.words.map {
            TranscriptionWord(text: $0.punctuatedWord ?? $0.word, start: $0.start, end: $0.end)
        }

        let segments: [TranscriptionSegment]
        if let utterances = decoded.results.utterances, !utterances.isEmpty {
            segments = utterances.map { TranscriptionSegment(text: $0.transcript, start: $0.start, end: $0.end) }
        } else if !alt.transcript.isEmpty {
            let start = alt.words.first?.start ?? 0
            let end = alt.words.last?.end ?? start
            segments = [TranscriptionSegment(text: alt.transcript, start: start, end: end)]
        } else {
            segments = []
        }

        if alt.transcript.isEmpty && segments.isEmpty { throw DeepgramError.emptyTranscript }

        let lang = decoded.results.channels.first?.detectedLanguage ?? language
        return TranscriptionResult(text: alt.transcript, language: lang, words: words, segments: segments)
    }
}

/// Glue mirroring `Transcription.transcribeVideoAudio`: extract → upload → offset.
enum DeepgramTranscriber {
    static func transcribe(
        sourceURL: URL, range: ClosedRange<Double>?, language: String?
    ) async throws -> TranscriptionResult {
        guard let key = DeepgramKeychain.load(), !key.isEmpty else { throw DeepgramError.missingAPIKey }
        let audioURL = try await AudioExtractor.extractToM4A(sourceURL: sourceURL, range: range)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try Task.checkCancellation()
        let result = try await DeepgramClient(apiKey: key)
            .transcribe(fileURL: audioURL, contentType: "audio/mp4", language: language)
        // Extracted audio starts at range.lowerBound; restore source-second timestamps.
        return result.offsetting(by: range?.lowerBound ?? 0)
    }
}

// MARK: - Response DTOs

private extension JSONDecoder {
    static var deepgram: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

private struct DGResponse: Decodable { let results: DGResults }
private struct DGResults: Decodable {
    let channels: [DGChannel]
    let utterances: [DGUtterance]?
}
private struct DGChannel: Decodable {
    let alternatives: [DGAlt]
    let detectedLanguage: String?
}
private struct DGAlt: Decodable {
    let transcript: String
    let words: [DGWord]
}
private struct DGUtterance: Decodable {
    let start: Double
    let end: Double
    let transcript: String
}
private struct DGWord: Decodable {
    let word: String
    let punctuatedWord: String?
    let start: Double
    let end: Double
}
private struct DGErrorBody: Decodable {
    let errCode: String?
    let errMsg: String?
    let error: String?
    let message: String?
}
