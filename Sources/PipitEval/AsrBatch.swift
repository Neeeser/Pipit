import Foundation
import PipitCore

/// One file's transcription in a `pipit-eval asr --json` batch.
///
/// Word timings travel with the text because the echo harness scores by when
/// a word was said, not only whether it was.
struct AsrBatchResult: Codable {
    struct Word: Codable {
        var start: Double
        var end: Double
        var text: String
    }

    var file: String
    var text: String
    var words: [Word]

    init(file: String, output: TranscriptionOutput) {
        self.file = file
        text = output.text
        words = output.segments.flatMap { segment in
            (segment.words ?? []).map { word in
                Word(start: segment.start + word.start, end: segment.start + word.end, text: word.text)
            }
        }
    }
}
