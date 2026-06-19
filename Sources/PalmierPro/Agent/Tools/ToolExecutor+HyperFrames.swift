import Foundation

private struct RenderHyperframesInput: DecodableToolArgs {
    let html: String
    let durationSeconds: Double
    let width: Int?
    let height: Int?
    let fps: Double?
    let name: String?
    let folderId: String?
    static let allowedKeys: Set<String> = ["html", "durationSeconds", "width", "height", "fps", "name", "folderId"]
}

@MainActor
extension ToolExecutor {
    func renderHyperframes(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: RenderHyperframesInput = try decodeToolArgs(args, path: "render_hyperframes")

        let html = input.html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !html.isEmpty else {
            throw ToolError("html is required and must be a complete, self-contained HTML document.")
        }
        guard input.durationSeconds > 0, input.durationSeconds <= 600 else {
            throw ToolError("durationSeconds must be > 0 and <= 600.")
        }
        let width = max(16, min(3840, input.width ?? 1920))
        let height = max(16, min(2160, input.height ?? 1080))
        let fps = min(60, max(1, input.fps ?? 30))

        // Write into the project's media dir (persistent) so the asset URL stays valid;
        // mirrors EditorViewModel.importPastedImageData. Temp dir when no project is open.
        let filename = "hf-\(UUID().uuidString.prefix(8)).mp4"
        let destURL: URL
        if let projectURL = editor.projectURL {
            let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            destURL = mediaDir.appendingPathComponent(filename)
        } else {
            destURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }

        let request = HFRenderRequest(
            html: html, durationSeconds: input.durationSeconds,
            width: width, height: height, fps: fps, outputURL: destURL)

        let frames: Int
        do {
            frames = try await HyperFramesRenderer().render(request)
        } catch {
            throw ToolError("HyperFrames render failed: \(error.localizedDescription)")
        }

        guard let asset = editor.addMediaAsset(from: destURL) else {
            throw ToolError("Rendered the MP4 but failed to import it as a media asset.")
        }
        applyImportMetadata(editor: editor, asset: asset, name: input.name, folderId: input.folderId)

        return .ok("""
        Rendered HyperFrames composition '\(asset.name)' (id: \(asset.id), \(width)x\(height) @ \(Int(fps))fps, ~\(frames) frames). \
        It is now in the media library. Call add_clips with mediaRef \(asset.id) to place it on the timeline.
        """)
    }
}
