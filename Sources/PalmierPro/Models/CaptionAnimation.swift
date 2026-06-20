import Foundation

/// Entrance animation for a single caption clip (CapCut-style "legendas entrando").
/// Produces clip-relative keyframe tracks the caption pipeline injects into each
/// word/phrase clip so it pops/fades in synced to the spoken word.
struct CaptionAnimation: Codable, Sendable, Equatable {
    enum Style: String, Codable, CaseIterable, Sendable {
        case popIn, bounce, fade, typewriter

        var label: String {
            switch self {
            case .popIn: "Pop"
            case .bounce: "Bounce"
            case .fade: "Fade"
            case .typewriter: "Typewriter"
            }
        }

        /// Typewriter reads as one word at a time — caller defaults to 1 word/caption.
        var prefersOneWord: Bool { self == .typewriter }
    }

    var style: Style = .popIn
    /// Length of the entrance, in frames.
    var entryFrames: Int = 4
    /// Scale the word starts at before popping to 1.0 (pop/bounce only).
    var scaleStart: Double = 0.6

    /// Build clip-relative entrance keyframe tracks for a clip of `durationFrames`.
    /// Returns nil tracks for properties this style doesn't animate.
    func tracks(durationFrames: Int) -> (scale: KeyframeTrack<AnimPair>?, opacity: KeyframeTrack<Double>?) {
        let n = max(1, min(entryFrames, max(1, durationFrames - 1)))
        let opacity = KeyframeTrack<Double>(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .smooth),
            Keyframe(frame: n, value: 1.0, interpolationOut: .smooth),
        ])
        switch style {
        case .fade, .typewriter:
            return (nil, opacity)
        case .popIn:
            let scale = KeyframeTrack<AnimPair>(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: scaleStart, b: scaleStart), interpolationOut: .smooth),
                Keyframe(frame: n, value: AnimPair(a: 1, b: 1), interpolationOut: .smooth),
            ])
            return (scale, opacity)
        case .bounce:
            let peak = n
            let settle = n + max(2, n / 2)
            let scale = KeyframeTrack<AnimPair>(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: scaleStart, b: scaleStart), interpolationOut: .smooth),
                Keyframe(frame: peak, value: AnimPair(a: 1.12, b: 1.12), interpolationOut: .smooth),
                Keyframe(frame: settle, value: AnimPair(a: 1, b: 1), interpolationOut: .smooth),
            ])
            return (scale, opacity)
        }
    }
}
