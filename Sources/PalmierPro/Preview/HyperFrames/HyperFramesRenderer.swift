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

        // 1. Window + web view. Park it so only a ~2px corner sits on the main screen: a fully
        //    offscreen window is treated as hidden → WebKit pauses requestAnimationFrame (the
        //    per-frame seek awaits rAF) → every frame stalls on its 10s timeout (~15 min total).
        //    A sliver on-screen keeps the window "visible" so rAF fires; the snapshot still
        //    captures the full view regardless of where the window sits.
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let rect = NSRect(x: screen.minX - CGFloat(w) + 2, y: screen.minY - CGFloat(h) + 2,
                          width: CGFloat(w), height: CGFloat(h))
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

        // An offscreen window makes WebKit treat the page as hidden, which PAUSES
        // requestAnimationFrame — the per-frame seek awaits rAF, so each frame then stalls on
        // its 10s timeout (~15 min for a title). Disable occlusion detection so the page stays
        // "visible" and rAF keeps firing. Restored in teardown().
        Self.setOcclusionDetection(false)

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
        // afterScreenUpdates=false is critical: the seek already waits on requestAnimationFrame
        // (paint is committed), so the default `true` only adds a second full screen-update sync —
        // pathologically slow (seconds/frame) on an offscreen, occlusion-throttled window.
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        config.afterScreenUpdates = false
        for i in 0..<totalFrames {
            try Task.checkCancellation()
            await seekFrame(t: Double(i) / fps, fps: fps, frame: i)

            let image = try await view.takeSnapshot(configuration: config)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                Log.app.error("HyperFrames: snapshot \(i) produced no CGImage (reps: \(image.representations.count))")
                throw HFError.snapshotFailed(i)
            }
            if i == 0, Self.looksBlank(cgImage) {
                Log.app.error("HyperFrames: first frame is blank/transparent — the scene may not be rendering. Check that GSAP and all assets are inlined and <body> has an opaque background.")
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

    // MARK: - Seek

    /// Seek + paint one frame, hard-bounded (10s) so a wedged WebKit compositor —
    /// where requestAnimationFrame never fires — can't hang the whole render.
    private func seekFrame(t: Double, fps: Double, frame: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            Task { @MainActor [weak self] in
                do {
                    _ = try await self?.webView?.callAsyncJavaScript(
                        HyperFramesJS.seekBody, arguments: ["t": t, "fps": fps], contentWorld: .page)
                } catch {
                    Log.app.error("HyperFrames seek failed at frame \(frame): \(error.localizedDescription)")
                }
                once.fire()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                once.fire(timedOutFrame: frame)
            }
        }
    }

    /// True when the whole image averages to fully transparent — a throttled/blank capture.
    private static func looksBlank(_ cgImage: CGImage) -> Bool {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpaceCreateDeviceRGB()
        return pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress, let ctx = CGContext(
                data: base, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return raw[3] == 0
        }
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

    /// Toggle app-wide window occlusion detection (private NSApplication API, responds-guarded
    /// so it's a no-op if unavailable). Off = WebKit keeps offscreen pages rendering + rAF firing.
    private static func setOcclusionDetection(_ enabled: Bool) {
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        let app = NSApplication.shared
        guard app.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let imp = app.method(for: sel)
        unsafeBitCast(imp, to: Fn.self)(app, sel, ObjCBool(enabled))
    }

    private func teardown() {
        Self.setOcclusionDetection(true)
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

/// Guards a seek continuation so exactly one of {seek-finished, timeout} resumes it.
/// MainActor-isolated → both firing tasks serialize, no double-resume.
@MainActor
private final class ResumeOnce {
    private var cont: CheckedContinuation<Void, Never>?
    init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }
    func fire(timedOutFrame: Int? = nil) {
        guard cont != nil else { return }
        if let frame = timedOutFrame {
            Log.app.error("HyperFrames seek timed out at frame \(frame) — capturing current paint.")
        }
        cont?.resume()
        cont = nil
    }
}
