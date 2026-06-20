import Foundation

extension CaptionBuilder {
    /// Group consecutive transcribed words into short caption phrases (CapCut "word-by-word"
    /// style): at most `groupSize` words each, never wider than `fits` allows. Each phrase is
    /// timed from its first word's start to its last word's end so it shows while spoken.
    static func wordPhrases(
        for words: [TranscriptionWord],
        groupSize: Int,
        fits: (String) -> Bool
    ) -> [Phrase] {
        let timed: [(text: String, start: Double, end: Double)] = words.compactMap { w in
            let text = w.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let s = w.start, let e = w.end else { return nil }
            return (text, s, max(e, s))
        }
        guard !timed.isEmpty else { return [] }

        let cap = max(1, groupSize)
        var phrases: [Phrase] = []
        var i = 0
        while i < timed.count {
            var j = i
            var text = timed[i].text
            while j + 1 < timed.count, (j - i + 1) < cap {
                let candidate = text + " " + timed[j + 1].text
                if !fits(candidate) { break }
                text = candidate
                j += 1
            }
            phrases.append(Phrase(text: text, start: timed[i].start, end: timed[j].end))
            i = j + 1
        }
        return phrases
    }
}
