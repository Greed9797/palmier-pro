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
        var width = max(16, min(3840, input.width ?? 1920))
        var height = max(16, min(2160, input.height ?? 1080))
        // Cap render work to a ~1080p pixel budget, preserving aspect. A full-res render of
        // hundreds of frames via WebView snapshot is slow enough to blow the agent CLI's timeout
        // (a 4K 7s title = 210 frames → minutes → killed before add_clips → nothing lands).
        // Overlays/titles are vector; the editor composites this onto the real timeline size.
        let pixelBudget = 1920.0 * 1080.0
        let px = Double(width) * Double(height)
        if px > pixelBudget {
            let s = (pixelBudget / px).squareRoot()
            width = max(16, Int((Double(width) * s).rounded()) & ~1)
            height = max(16, Int((Double(height) * s).rounded()) & ~1)
        }
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
