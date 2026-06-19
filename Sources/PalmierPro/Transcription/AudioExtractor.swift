import AVFoundation
import Foundation

/// Extracts the audio of a source file to a compact temp .m4a (AAC) for cloud upload.
/// Optional `range` (source seconds) trims to just the window we need to caption.
/// Reuses the AVMutableComposition + AVAssetExportPresetAppleM4A pattern already used
/// by EditorViewModel.exportClipRange. Caller owns the returned file and must delete it.
enum AudioExtractor {
    static func extractToM4A(sourceURL: URL, range: ClosedRange<Double>?) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DeepgramError.audioExtractionFailed("no audio track in \(sourceURL.lastPathComponent)")
        }

        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw DeepgramError.audioExtractionFailed("could not create composition track")
        }

        let duration = try await asset.load(.duration)
        let timeRange: CMTimeRange
        if let range {
            let start = CMTime(seconds: max(0, range.lowerBound), preferredTimescale: 600)
            let end = CMTime(seconds: range.upperBound, preferredTimescale: 600)
            timeRange = CMTimeRange(start: start, end: min(end, CMTimeRangeMake(start: .zero, duration: duration).end))
        } else {
            timeRange = CMTimeRange(start: .zero, duration: duration)
        }

        do {
            try compTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
        } catch {
            throw DeepgramError.audioExtractionFailed(error.localizedDescription)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dg-\(UUID().uuidString).m4a")

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw DeepgramError.audioExtractionFailed("AVAssetExportPresetAppleM4A unavailable")
        }

        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            throw DeepgramError.audioExtractionFailed(error.localizedDescription)
        }
        return outputURL
    }
}
