import AppKit
import AVFoundation
import CoreVideo
import WebKit

struct HFRenderRequest: Sendable {
    let html: String
    let durationSeconds: Double
    let width: Int
    let height: Int
    let fps: Double
    let outputURL: URL
}

enum HFError: LocalizedError {
    case loadFailed(String)
    case notReady
    case badDuration
    case encodeSetupFailed
    case snapshotFailed(Int)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): "Scene failed to load: \(m)"
        case .notReady: "Scene never became ready (missing window.__hf.seek / duration, or assets didn't load). Inline GSAP and all fonts/images as data URIs."
        case .badDuration: "Composition duration is zero or invalid."
        case .encodeSetupFailed: "Could not initialize the video encoder."
        case .snapshotFailed(let i): "Failed to capture frame \(i)."
        case .encodeFailed(let m): "Encoding failed: \(m)"
        }
    }
}

/// Renders an agent-authored HTML/CSS/GSAP scene to an MP4 natively: an offscreen
/// WKWebView paints each frame after a deterministic GSAP seek; frames are captured
/// and encoded with AVFoundation. No Node/Chrome/FFmpeg. All AV objects stay on the
/// main actor (mirrors LottieVideoGenerator) — no cross-actor non-Sendable handoff.
@MainActor
final class HyperFramesRenderer: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    /// Returns the number of frames actually encoded.
    func render(_ req: HFRenderRequest, progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        defer { teardown() }

        let w = max(2, req.width - req.width % 2)
        let h = max(2, req.height - req.height % 2)
        let fps = req.fps > 0 ? req.fps : 30

        // 1. Offscreen window + web view (must be on-screen-but-offscreen, not hidden,
        //    or the web content process never allocates a backing surface).
        let rect = NSRect(x: -20_000, y: -20_000, width: CGFloat(w), height: CGFloat(h))
        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                             configuration: WKWebViewConfiguration())
        view.navigationDelegate = self
        win.contentView = view
        NSApplication.shared.activate(ignoringOtherApps: false)
        win.orderFrontRegardless()
        self.window = win
        self.webView = view

        // 2. Load HTML (baseURL nil → no network/file access; assets must be inlined).
        //    Bounded by a timeout so a web-content-process crash / silent cancel can't hang forever.
        let loadTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.loadContinuation != nil else { return }
            self.loadContinuation?.resume(throwing: HFError.loadFailed("load timed out"))
            self.loadContinuation = nil
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.loadContinuation = cont
                self.webView?.loadHTMLString(req.html, baseURL: nil)
            }
            loadTimeout.cancel()
        } catch {
            loadTimeout.cancel()
            throw error
        }

        // 3. Wait for the scene to be seekable + assets decoded (cap ~6s).
        try await awaitReady(view, tries: 120)

        // 4. Resolve duration → frame count.
        let jsDuration = (try? await view.evaluateJavaScript(HyperFramesJS.durationExpr)) as? Double ?? 0
        let duration = max(jsDuration, req.durationSeconds)
        guard duration > 0, duration.isFinite else { throw HFError.badDuration }
        let totalFrames = max(1, Int((duration * fps).rounded(.up)))

        // 5. Encoder.
        try setupWriter(url: req.outputURL, width: w, height: h)
        guard let pool = adaptor?.pixelBufferPool else { throw HFError.encodeSetupFailed }

        // 6. Per-frame: seek → snapshot → append (strictly one frame in flight).
        for i in 0..<totalFrames {
            try Task.checkCancellation()
            let t = Double(i) / fps
            do {
                _ = try await view.callAsyncJavaScript(
                    HyperFramesJS.seekBody, arguments: ["t": t, "fps": fps], contentWorld: .page)
            } catch {
                Log.app.error("HyperFrames seek failed at frame \(i): \(error.localizedDescription)")
            }

            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            let image = try await view.takeSnapshot(configuration: config)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw HFError.snapshotFailed(i)
            }
            try await appendFrame(cgImage, index: i, pool: pool, fps: fps, width: w, height: h)
            progress?(i + 1, totalFrames)
        }

        // 7. Finish.
        try await finishWriter()
        return totalFrames
    }

    // MARK: - Readiness

    private func awaitReady(_ view: WKWebView, tries: Int) async throws {
        for _ in 0..<tries {
            let ready = (try? await view.evaluateJavaScript(HyperFramesJS.readinessExpr)) as? Bool ?? false
            if ready { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HFError.notReady
    }

    // MARK: - Encoder

    private func setupWriter(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw HFError.encodeSetupFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw HFError.encodeFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.videoInput = input
        self.adaptor = adaptor
    }

    private func appendFrame(
        _ cgImage: CGImage, index: Int, pool: CVPixelBufferPool, fps: Double, width: Int, height: Int
    ) async throws {
        guard let input = videoInput, let adaptor else { throw HFError.encodeSetupFailed }
        var bufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut) == kCVReturnSuccess,
              let buffer = bufferOut else {
            throw HFError.encodeFailed("pixel buffer pool exhausted at frame \(index)")
        }
        autoreleasepool {
            CVPixelBufferLockBaseAddress(buffer, [])
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while !input.isReadyForMoreMediaData {
            if let writer, writer.status == .failed {
                throw HFError.encodeFailed(writer.error?.localizedDescription ?? "writer failed at frame \(index)")
            }
            if ContinuousClock.now > deadline { throw HFError.encodeFailed("encoder stalled at frame \(index)") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pts = CMTimeMakeWithSeconds(Double(index) / fps, preferredTimescale: 600)
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw HFError.encodeFailed(writer?.error?.localizedDescription ?? "append failed at frame \(index)")
        }
    }

    private func finishWriter() async throws {
        guard let writer, let input = videoInput else { throw HFError.encodeSetupFailed }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw HFError.encodeFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    private func teardown() {
        loadContinuation?.resume(throwing: HFError.loadFailed("renderer torn down"))
        loadContinuation = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.orderOut(nil)
        webView = nil
        window = nil
        writer = nil
        videoInput = nil
        adaptor = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: HFError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: HFError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }
}
